import 'package:uuid/uuid.dart';
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
// import 'package:flutter/rendering.dart' as rendering; // removed (diagnostics only)
import 'package:flutter/gestures.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/timetable/timetable_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'services/data_manager.dart';
import 'services/sync_service.dart';
import 'models/memo.dart';
import 'models/student.dart';
import 'models/education_level.dart';
import 'services/ai_summary.dart';
import 'dart:async';
import 'dart:convert';
import 'services/exam_mode.dart';
import 'services/academy_db.dart';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'services/tag_preset_service.dart';
import 'services/tag_store.dart';
import 'tools/backfill_runner.dart';

// 테스트 전용: 전역 RawKeyboardListener의 autofocus를 끌 수 있는 플래그 (기본값: 유지)
const bool kDisableGlobalKbAutofocus = bool.fromEnvironment('DISABLE_GLOBAL_KB_AUTOFOCUS', defaultValue: false);

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();
final GlobalKey<ScaffoldMessengerState> rootScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

// 시험명 목록과 선택된 학교/학년 매핑(메모리 보관)
final ValueNotifier<List<String>> _examNames = ValueNotifier<List<String>>(<String>[]);
// examName -> (schoolKey -> set of grades)
final Map<String, Map<String, Set<int>>> _examAssignmentByName = <String, Map<String, Set<int>>>{};

// 선호출(프리로드) 결과를 위저드와 공유하기 위한 임시 저장소
final Map<String, Map<DateTime, List<String>>> _preloadedSavedBySg = <String, Map<DateTime, List<String>>>{};
final Map<String, Map<DateTime, String>> _preloadedRangesBySg = <String, Map<DateTime, String>>{};

// 반복되는 시맨틱스 어설션 스팸을 1회로 제한하기 위한 플래그
bool _printedFirstSemanticsDirty = false;

String _sgSchool(String sg) {
  final idx = sg.lastIndexOf(' ');
  return idx > 0 ? sg.substring(0, idx) : sg;
}

int _sgGrade(String sg) {
  final idx = sg.lastIndexOf(' ');
  final gradeText = idx > 0 ? sg.substring(idx + 1) : '';
  return int.tryParse(gradeText.replaceAll('학년', '')) ?? 0;
}

Future<void> _preloadExamDataFor(List<String> sgLabels, EducationLevel level) async {
  for (final sg in sgLabels) {
    final school = _sgSchool(sg);
    final gradeNum = _sgGrade(sg);
    final res = await DataManager.instance.loadExamFor(school, level, gradeNum);
    // schedules
    final Map<DateTime, List<String>> saved = <DateTime, List<String>>{};
    final schedules = (res['schedules'] as List?)?.cast<Map<String, dynamic>>() ?? const <Map<String, dynamic>>[];
    for (final row in schedules) {
      final dateIso = (row['date'] as String?) ?? '';
      if (dateIso.isEmpty) continue;
      final d = DateTime.parse(dateIso);
      final key = DateTime(d.year, d.month, d.day);
      final namesJson = (row['names_json'] as String?) ?? '[]';
      List<dynamic> list;
      try { list = jsonDecode(namesJson); } catch (_) { list = []; }
      saved[key] = list.map((e) => e.toString()).toList();
    }
    if (saved.isNotEmpty) {
      _preloadedSavedBySg[sg] = saved;
    }
    // ranges
    final Map<DateTime, String> ranges = <DateTime, String>{};
    final rangesRows = (res['ranges'] as List?)?.cast<Map<String, dynamic>>() ?? const <Map<String, dynamic>>[];
    for (final row in rangesRows) {
      final dateIso = (row['date'] as String?) ?? '';
      if (dateIso.isEmpty) continue;
      final d = DateTime.parse(dateIso);
      final key = DateTime(d.year, d.month, d.day);
      final text = (row['range_text'] as String?) ?? '';
      ranges[key] = text;
    }
    if (ranges.isNotEmpty) {
      _preloadedRangesBySg[sg] = ranges;
    }
  }
}

Future<void> _preloadExamDialogData() async {
  // 학년 필터 불러와 대상 SG 라벨 산출 후 프리로드
  final prefs = await SharedPreferences.getInstance();
  final List<String> filter = prefs.getStringList('exam_dialog_grade_filter') ?? const <String>[];
  String _prefix(EducationLevel l) => l == EducationLevel.middle ? 'M' : (l == EducationLevel.high ? 'H' : '');
  // 유니크한 (school, level, grade) → 라벨
  final Set<String> seen = <String>{};
  final List<Map<String, dynamic>> items = <Map<String, dynamic>>[];
  for (final s in DataManager.instance.students) {
    final level = s.student.educationLevel;
    if (level == EducationLevel.elementary) continue;
    final school = s.student.school.trim();
    final grade = s.student.grade;
    final key = '${level.index}|$school|$grade';
    if (seen.contains(key)) continue;
    seen.add(key);
    final fkey = '${_prefix(level)}$grade';
    // 필터가 비어있으면 전체 프리로드, 아니면 필터된 대상만 프리로드
    if (filter.isEmpty || filter.contains(fkey)) {
      items.add({'school': school, 'level': level, 'grade': grade});
    }
  }
  final List<String> middleAll = items.where((m) => m['level'] == EducationLevel.middle).map((m) => '${m['school']} ${m['grade']}학년').toList();
  final List<String> highAll = items.where((m) => m['level'] == EducationLevel.high).map((m) => '${m['school']} ${m['grade']}학년').toList();
  // 이미 프리로드된 항목은 재요청 생략
  bool _hasPreloaded(String label) {
    return _preloadedSavedBySg.containsKey(label) || _preloadedRangesBySg.containsKey(label);
  }
  final List<String> middle = middleAll.where((l) => !_hasPreloaded(l)).toList();
  final List<String> high = highAll.where((l) => !_hasPreloaded(l)).toList();
  if (middle.isEmpty && high.isEmpty) return;
  await Future.wait([
    _preloadExamDataFor(middle, EducationLevel.middle),
    _preloadExamDataFor(high, EducationLevel.high),
  ]);
}

// ===== 과목/배정 영속화 =====
const String _kExamNamesKey = 'exam_names_json';
const String _kExamAssignKey = 'exam_assign_json';

Future<void> _loadExamMetaPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  try {
    final namesJson = prefs.getString(_kExamNamesKey);
    if (namesJson != null && namesJson.isNotEmpty) {
      final list = (jsonDecode(namesJson) as List).map((e) => e.toString()).toList();
      _examNames.value = List<String>.from(list);
    }
  } catch (_) {}
  try {
    final assignJson = prefs.getString(_kExamAssignKey);
    if (assignJson != null && assignJson.isNotEmpty) {
      final raw = jsonDecode(assignJson) as Map<String, dynamic>;
      _examAssignmentByName.clear();
      raw.forEach((name, m) {
        final inner = <String, Set<int>>{};
        (m as Map<String, dynamic>).forEach((k, v) {
          inner[k] = (v as List).map((e) => (e as num).toInt()).toSet();
        });
        _examAssignmentByName[name] = inner;
      });
    }
  } catch (_) {}
}

Future<void> _saveExamMetaPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  try {
    await prefs.setString(_kExamNamesKey, jsonEncode(_examNames.value));
  } catch (_) {}
  try {
    final Map<String, dynamic> map = {
      for (final entry in _examAssignmentByName.entries)
        entry.key: { for (final e in entry.value.entries) e.key: e.value.toList() }
    };
    await prefs.setString(_kExamAssignKey, jsonEncode(map));
  } catch (_) {}
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 에러 로그 스팸 억제: 시맨틱스 parentDataDirty 반복은 최초 1회만 저장
  FlutterError.onError = (FlutterErrorDetails details) {
    final String message = details.exceptionAsString();
    if (!_printedFirstSemanticsDirty && message.contains("!semantics.parentDataDirty")) {
      _printedFirstSemanticsDirty = true;
      // ignore: avoid_print
      print('[SEMANTICS] First occurrence captured. See details below.');
      FlutterError.dumpErrorToConsole(details, forceReport: true);
    } else if (!message.contains("!semantics.parentDataDirty")) {
      FlutterError.dumpErrorToConsole(details, forceReport: true);
    }
  };
  // Supabase init (desktop에서도 동작). URL/KEY는 dart-define으로 주입
  final supabaseUrl = const String.fromEnvironment('SUPABASE_URL', defaultValue: '');
  final supabaseAnonKey = const String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: '');
  if (supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty) {
    await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
  }
  // 데이터 경로 제어 플래그(dart-define로 런타임 제어)
  try {
    final dual = const String.fromEnvironment('DUAL_WRITE', defaultValue: 'true');
    final prefer = const String.fromEnvironment('PREFER_SUPABASE', defaultValue: 'true');
    // 태그 프리셋 서비스에만 우선 적용. 이후 점진 확장.
    TagPresetService.configure(
      dualWriteOn: dual.toLowerCase() == 'true',
      preferSupabase: prefer.toLowerCase() == 'true',
    );
    // Tag events(TagStore)에도 동일 적용
    TagStore.configure(
      dualWriteOn: dual.toLowerCase() == 'true',
      preferSupabase: prefer.toLowerCase() == 'true',
    );
    // 디버깅 로그
    // ignore: avoid_print
    print('[Boot] TagPresetService flags -> dualWrite=' + TagPresetService.dualWrite.toString() + ', preferSupabaseRead=' + TagPresetService.preferSupabaseRead.toString());
    // ignore: avoid_print
    print('[Boot] TagStore flags -> dualWrite=' + TagStore.dualWrite.toString() + ', preferSupabaseRead=' + TagStore.preferSupabaseRead.toString());
  } catch (_) {}
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
  // 백필 실행 플래그
  const runBackfill = String.fromEnvironment('RUN_BACKFILL', defaultValue: 'false');
  if (runBackfill.toLowerCase() == 'true') {
    // 서버 쓰기만 허용, 읽기는 로컬 우선 권장
    // ignore: unawaited_futures
    (() async {
      try {
        final dual = const String.fromEnvironment('DUAL_WRITE', defaultValue: 'false');
        final prefer = const String.fromEnvironment('PREFER_SUPABASE', defaultValue: 'false');
        TagPresetService.configure(
          dualWriteOn: dual.toLowerCase() == 'true',
          preferSupabase: prefer.toLowerCase() == 'true',
        );
        TagStore.configure(
          dualWriteOn: dual.toLowerCase() == 'true',
          preferSupabase: prefer.toLowerCase() == 'true',
        );
      } catch (_) {}
      // 도메인 데이터 백필(파괴적 삭제 없음)
      await BackfillRunner.runAll();
    })();
  }
  // 과목/배정 메타 로드 (앱 시작 시 1회)
  await _loadExamMetaPrefs();
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
          await ExamModeService.instance.initialize();
          await SyncService.instance.runInitialSyncIfNeeded();
          // until 미설정 또는 과거인 경우 DB 기반 자동 복원
          await ExamModeService.instance.ensureOnFromDatabase(
            () => AcademyDbService.instance.loadAllExamDays(),
            () => AcademyDbService.instance.loadAllExamSchedules(),
          );
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
              // 최종 요구 순서: 화면 → 플로팅 메모 → FAB(+ 및 드롭다운) → 메모 슬라이드
              return Overlay(initialEntries: [
                OverlayEntry(builder: (ctx) => child ?? const SizedBox.shrink()),
                OverlayEntry(builder: (ctx) => const _GlobalMemoFloatingBanners()),
                OverlayEntry(builder: (ctx) => const _GlobalExamOverlay()),
                OverlayEntry(builder: (ctx) => const _GlobalMemoOverlay()),
              ]);
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

Future<void> _openRangeAddDialog(BuildContext context) async {
  await showDialog(
    context: context,
    builder: (ctx) {
      final ctrlRange = TextEditingController();
      final List<String> candidates = _examNames.value.isEmpty ? <String>['수학'] : [..._examNames.value]..sort();
      String selectedName = candidates.first;
      return StatefulBuilder(builder: (ctxSB, setSB) {
      return AlertDialog(
        backgroundColor: const Color(0xFF1F1F1F),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('시험명/범위 추가', style: TextStyle(color: Colors.white)),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
                DropdownButtonHideUnderline(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white24),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: DropdownButton<String>(
                      value: selectedName,
                      dropdownColor: const Color(0xFF1F1F1F),
                      iconEnabledColor: Colors.white70,
                style: const TextStyle(color: Colors.white),
                      items: candidates
                          .map((e) => DropdownMenuItem<String>(value: e, child: Text(e)))
                          .toList(),
                      onChanged: (v) => setSB(() { if (v != null) selectedName = v; }),
                    ),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: ctrlRange,
                minLines: 2,
                maxLines: 4,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: '범위',
                  labelStyle: TextStyle(color: Colors.white70),
                  hintText: '예: 수학 I 1~3단원',
                  hintStyle: TextStyle(color: Colors.white38),
                  enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                  focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctxSB).pop(),
            child: const Text('취소', style: TextStyle(color: Colors.white70)),
          ),
          FilledButton(
              onPressed: () {
                // DEBUG: 범위 추가 저장 시도
                // ignore: avoid_print
                print('[RANGE_ADD] try save: selectedName=$selectedName, text="${ctrlRange.text}"');
                final state = context.findAncestorStateOfType<_ExamScheduleWizardState>();
                // ignore: avoid_print
                print('[RANGE_ADD] found wizard state? ${state != null}');
                final sg = state?._selectedSchoolGrade;
                if (state != null && sg != null) {
                  state.setState(() {
                    final list = state._rangeBadgesBySchoolGrade[sg] ?? <String>[];
                    final text = ctrlRange.text.trim();
                    if (text.isNotEmpty) {
                      list.add('$selectedName: $text');
                      state._rangeBadgesBySchoolGrade[sg] = list;
                      // ignore: avoid_print
                      print('[RANGE_ADD] saved temp badge: sg=$sg, list=${state._rangeBadgesBySchoolGrade[sg]}');
                    }
                  });
                }
                Navigator.of(ctxSB).pop();
              },
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
            child: const Text('추가'),
          ),
        ],
      );
      });
    },
  );
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
            final dlgCtx = rootNavigatorKey.currentContext ?? context;
            final text = await showDialog<String>(
              context: dlgCtx,
              builder: (_) => const _MemoInputDialog(),
            );
            if (text == null || text.trim().isEmpty) return;
            final now = DateTime.now();
            final memo = Memo(
              id: const Uuid().v4(),
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
            final dlgCtx = rootNavigatorKey.currentContext ?? context;
            final edited = await showDialog<_MemoEditResult>(
              context: dlgCtx,
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

// 날짜 선택 다이얼로그(저장 가능, 이름 입력 다이얼로그에서 복귀)
Future<Map<DateTime, List<String>>?> _openDateSelectAndSaveDialog(BuildContext context, List<DateTime> days, {String? schoolGradeLabel}) async {
  final List<DateTime> sorted = [...days]..sort();
  final Map<DateTime, List<String>> localTitles = {};
  Map<DateTime, List<String>>? result;
  // 선택된 학교/학년에 매칭되는 시험명 목록 산출
  List<String> _examNamesFor(String? sgLabel) {
    if (sgLabel == null || sgLabel.isEmpty) return _examNames.value.isEmpty ? <String>['수학'] : [..._examNames.value];
    final re = RegExp(r'^(.*)\s+(\d+)학년$');
    String schoolName = sgLabel;
    int? grade;
    final m = re.firstMatch(sgLabel);
    if (m != null) {
      schoolName = m.group(1)!.trim();
      grade = int.tryParse(m.group(2)!);
    }
    EducationLevel? level;
    for (final s in DataManager.instance.students) {
      if (s.student.school.trim() == schoolName && (grade == null || s.student.grade == grade)) {
        level = s.student.educationLevel;
        break;
      }
    }
    if (level == null) {
      // fallback: 동일 학교 아무 레벨이나
      for (final s in DataManager.instance.students) {
        if (s.student.school.trim() == schoolName) { level = s.student.educationLevel; break; }
      }
    }
    if (level == null) return _examNames.value.isEmpty ? <String>['수학'] : [..._examNames.value];
    final schoolKey = '${level.index}|$schoolName';
    final Set<String> names = <String>{};
    _examAssignmentByName.forEach((name, assign) {
      final set = assign[schoolKey];
      if (set != null && (grade == null || set.contains(grade))) {
        names.add(name);
      }
    });
    if (names.isEmpty) names.add('수학');
    final list = names.toList()..sort();
    return list;
  }
  final List<String> candidateNames = _examNamesFor(schoolGradeLabel);
  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) {
      return StatefulBuilder(builder: (ctxSB, setSB) {
        Future<void> addTitleFor(DateTime d) async {
          final text = await showDialog<String>(
            context: ctxSB,
            builder: (ctx2) {
              final ctrl = TextEditingController();
              return AlertDialog(
                backgroundColor: const Color(0xFF1F1F1F),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                title: Text('${d.year}.${d.month}.${d.day} 시험명', style: const TextStyle(color: Colors.white)),
                content: SizedBox(
                  width: 420,
                  child: TextField(
                    controller: ctrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      hintText: '예: 중간고사 수학',
                      hintStyle: TextStyle(color: Colors.white38),
                      enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                      focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
                    ),
                  ),
                ),
                actions: [
                  TextButton(onPressed: () => Navigator.of(ctx2).pop(), child: const Text('취소', style: TextStyle(color: Colors.white70))),
                  FilledButton(onPressed: () => Navigator.of(ctx2).pop(ctrl.text.trim()), style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)), child: const Text('저장')),
                ],
              );
            },
          );
          if (text != null && text.isNotEmpty) {
            setSB(() {
              final key = DateTime(d.year, d.month, d.day);
              final cur = localTitles[key] ?? [];
              localTitles[key] = [...cur, text];
            });
          }
        }

        return AlertDialog(
          backgroundColor: const Color(0xFF1F1F1F),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          title: const Text('날짜 선택', style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: 360,
            height: 300,
            child: ListView.builder(
              itemCount: sorted.length,
              itemBuilder: (c, i) {
                final d = sorted[i];
                final key = DateTime(d.year, d.month, d.day);
                final titles = localTitles[key] ?? [];
                final selected = titles.isNotEmpty ? titles.first : null;
                return ListTile(
                  title: Text('${d.year}.${d.month}.${d.day}', style: const TextStyle(color: Colors.white)),
                  trailing: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: selected != null && candidateNames.contains(selected) ? selected : null,
                      hint: const Text('시험명', style: TextStyle(color: Colors.white70)),
                      dropdownColor: const Color(0xFF1F1F1F),
                      style: const TextStyle(color: Colors.white),
                      items: candidateNames.map((e) => DropdownMenuItem<String>(value: e, child: Text(e))).toList(),
                      onChanged: (val) {
                        setSB(() {
                          final key = DateTime(d.year, d.month, d.day);
                          localTitles[key] = val == null ? <String>[] : <String>[val];
                        });
                      },
                    ),
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctxSB).pop(), child: const Text('닫기', style: TextStyle(color: Colors.white70))),
            FilledButton(
              onPressed: () {
                result = localTitles;
                Navigator.of(ctxSB).pop();
              },
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
              child: const Text('저장'),
            ),
          ],
        );
      });
    },
  );
  return result;
}

// 범위 편집 다이얼로그: 이미 등록된 시험명이 있을 때 날짜별로 범위를 추가/수정
Future<Map<DateTime, String>?> _openRangeEditDialog(BuildContext context, String schoolGradeKey, Map<DateTime, List<String>> savedNames) async {
  final Map<DateTime, String> localRanges = {};
  // DEBUG: 초기 상태 로깅
  // ignore: avoid_print
  print('[RANGE_EDIT][init] schoolGrade=$schoolGradeKey, saved dates=${savedNames.keys.toList()}');
  // 참고: 여기서는 기존 구현과 동일하게 임시 값으로 채우되, 실제 상태 객체 값도 비교 로그로 남긴다.
  savedNames.forEach((date, names) {
    final key = DateTime(date.year, date.month, date.day);
    final existingWrong = (_ExamScheduleWizardState()._rangesBySchoolGrade[schoolGradeKey] ?? {})[key] ?? '';
    final st = context.findAncestorStateOfType<_ExamScheduleWizardState>();
    final existingActual = st?._rangesBySchoolGrade[schoolGradeKey]?[key] ?? '';
    // ignore: avoid_print
    print('[RANGE_EDIT][init] date=$key, existing(wrongCtor)="$existingWrong", existing(actual)="$existingActual"');
    localRanges[key] = existingWrong;
  });
  final result = await showDialog<Map<DateTime, String>>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) {
      final sorted = savedNames.keys.toList()..sort();
      return AlertDialog(
        backgroundColor: const Color(0xFF1F1F1F),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('범위 입력', style: TextStyle(color: Colors.white)),
        content: SizedBox(
          width: 460,
          height: 360,
          child: ListView.builder(
            itemCount: sorted.length,
            itemBuilder: (c, i) {
              final d = sorted[i];
              final names = savedNames[d] ?? [];
              final dateLabel = '${d.year}.${d.month}.${d.day}';
              final firstName = names.isNotEmpty ? names.first : '';
              final ctrl = TextEditingController(text: localRanges[DateTime(d.year, d.month, d.day)] ?? '');
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(child: Text('$dateLabel  $firstName', style: const TextStyle(color: Colors.white, fontSize: 17))),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 260,
                      child: TextField(
                        controller: ctrl,
                        minLines: 1,
                        maxLines: 3,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          hintText: '범위 입력',
                          hintStyle: TextStyle(color: Colors.white38),
                          enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                          focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
                        ),
                        onChanged: (v) {
                          localRanges[DateTime(d.year, d.month, d.day)] = v;
                        },
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('닫기', style: TextStyle(color: Colors.white70))),
          FilledButton(
            onPressed: () {
              final map = <DateTime, String>{}..addAll(localRanges);
              // ignore: avoid_print
              print('[RANGE_EDIT][save] schoolGrade=$schoolGradeKey, savedKeys=${map.keys.toList()} values=${map.values.toList()}');
              Navigator.of(ctx).pop(map);
            },
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
            child: const Text('저장'),
          ),
        ],
      );
    },
  );
  return result;
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

  String _keyFor(Memo m) {
    // 메모의 예정일(YYYYMMDD) 기준으로 키 생성 → 해당 날짜 자정까지 표시/해제 동작 유지
    final dt = m.scheduledAt ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${m.id}:${dt.year}${two(dt.month)}${two(dt.day)}';
  }

  

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
    // FAB 드롭다운과 겹치지 않도록 좌측 하단으로 이동
    return Positioned(
      right: 30,
      bottom: 100,
      child: ValueListenableBuilder<List<Memo>>(
        valueListenable: DataManager.instance.memosNotifier,
        builder: (context, memos, _) {
          // 가까운 미래 포함, 해제되지 않은 배너만 (규칙에 맞게 미래도 표시)
          // 디버그: 전체/필터 단계별 카운트
          print('[FLOAT][DEBUG] total memos=${memos.length}');
          final withSchedule = memos.where((m) => m.scheduledAt != null).toList();
          print('[FLOAT][DEBUG] with scheduledAt != null: ${withSchedule.length}');
          final notDismissedFlag = withSchedule.where((m) => !m.dismissed).toList();
          print('[FLOAT][DEBUG] !dismissed (scheduled): ${notDismissedFlag.length}');
          final notSessionDismissed = notDismissedFlag.where((m) => !_sessionDismissed.contains(m.id)).toList();
          print('[FLOAT][DEBUG] !sessionDismissed (scheduled): ${notSessionDismissed.length}');
          // 일정 있는 메모: 미래 포함, 세션 해제/영구 해제 제외
          final scheduledCandidates = notSessionDismissed
              .toList()
            ..sort((a, b) => a.scheduledAt!.compareTo(b.scheduledAt!));
          // 일정 없는 메모: 삭제 전까지 항상 표시 (dismissed/세션 해제 무시)
          final unscheduledCandidates = memos
              .where((m) => m.scheduledAt == null)
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
                  // 무일정 메모는 삭제 전까지 항상 표시: X 동작 무시
                  if (m.scheduledAt == null) {
                    return;
                  }
                  // 일정 있는 메모: 세션 동안 숨김, 지난 일정이면 영구 숨김
                  setState(() {
                    _sessionDismissed.add(m.id);
                  });
                  if (DateTime.now().isAfter(m.scheduledAt!)) {
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
    _indicatorCtrl = AnimationController(vsync: this);
    final double v0 = ExamModeService.instance.speed.value.clamp(1.0, 30.0);
    final int sec0 = (31 - v0).clamp(1.0, 30.0).round();
    _indicatorCtrl.repeat(period: Duration(seconds: sec0));
    ExamModeService.instance.speed.addListener(() {
      final double v = ExamModeService.instance.speed.value.clamp(1.0, 30.0);
      final int sec = (31 - v).clamp(1.0, 30.0).round();
      _indicatorCtrl.stop();
      _indicatorCtrl.repeat(period: Duration(seconds: sec));
    });
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
                  child: ValueListenableBuilder<Color>(
                    valueListenable: ExamModeService.instance.indicatorColor,
                    builder: (context, color, _) {
                      return ValueListenableBuilder<String>(
                        valueListenable: ExamModeService.instance.effect,
                        builder: (context, effect, __) {
                          return AnimatedBuilder(
                    animation: _indicatorCtrl,
                    builder: (context, _) {
                              if (effect == 'breath') {
                                final t = (math.sin(_indicatorCtrl.value * 2 * math.pi) + 1) / 2; // 0..1
                                final opacity = 0.2 + 0.8 * t; // 0.2..1.0
                                return Container(color: color.withOpacity(opacity));
                              }
                              if (effect == 'solid') {
                                return Container(color: color.withOpacity(0.85));
                              }
                      return RepaintBoundary(child: _AnimatedLinearGlow(
                        progress: _indicatorCtrl.value,
                                baseColor: color,
                        dimOpacity: 0.35,
                        glowOpacity: 1.0,
                        bandFraction: 0.18,
                      ));
                            },
                          );
                        },
                      );
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
              // 다이얼로그 표시 전에 데이터 프리로드하여 초기 깜빡임 제거
              try { await _preloadExamDialogData(); } catch (_) {}
              // Route 애니메이션 비용 최소화를 위해 useRootNavigator + barrierDismissible true 유지
              await showDialog(
                context: rootNavigatorKey.currentContext!,
                builder: (ctx) => const _ExamScheduleDialog(),
              );
            }),
            const SizedBox(width: 12),
            _ExamActionButton(icon: Icons.assignment_turned_in, label: '기출', onPressed: () {
              rootScaffoldMessengerKey.currentState?.showSnackBar(const SnackBar(content: Text('기출 기능은 준비 중입니다.')));
            }),
            const SizedBox(width: 12),
            // 설정 버튼은 아이콘만
            _ExamIconOnlyButton(icon: Icons.settings, onPressed: () async {
              await showDialog(context: rootNavigatorKey.currentContext!, builder: (ctx) => const _ExamSettingsDialog());
            }),
            const SizedBox(width: 12),
            // 전광판: 저장된 시험일정 순환 표시
            _ExamTickerBoard(),
          ],
        ),
      ),
    );
  }
}

class _ExamTickerBoard extends StatefulWidget {
  @override
  State<_ExamTickerBoard> createState() => _ExamTickerBoardState();
}

class _ExamTickerBoardState extends State<_ExamTickerBoard> {
  List<Map<String, dynamic>> _items = [];
  int _index = 0;
  Timer? _timer;
  final double _fixedWidth = 220; // 고정 너비
  int? _hoverIndex;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted || _items.isEmpty) return;
      setState(() => _index = (_index + 1) % _items.length);
    });
    // 주기적 리로드
    Timer.periodic(const Duration(seconds: 20), (_) async {
      if (!mounted) return;
      await _load();
    });
  }

  Future<void> _load() async {
    final rows = await AcademyDbService.instance.loadAllExamSchedules();
    final list = List<Map<String, dynamic>>.from(rows);
    list.sort((a,b) => ((a['date'] as String?) ?? '').compareTo((b['date'] as String?) ?? ''));
    setState(() => _items = list);
  }

  @override
  void dispose() { _timer?.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) {
      return Container(
        width: _fixedWidth,
        constraints: const BoxConstraints(minHeight: 36),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: const Color(0xFF232326), borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.white24)),
        child: const Text('등록된 시험일정 없음', style: TextStyle(color: Colors.white38)),
      );
    }
    final it = _items[_index];
    final date = DateTime.tryParse(it['date'] as String? ?? '');
    String names = '';
    try {
      final raw = it['names_json'] as String?;
      if (raw != null && raw.isNotEmpty) {
        final list = (jsonDecode(raw) as List).map((e)=>e.toString()).toList();
        names = list.join(' / ');
      }
    } catch (_) {}
    final label = '${it['school']} ${it['grade']}학년 · ${date != null ? '${date.month}.${date.day}' : ''}${names.isNotEmpty ? ' · $names' : ''}';
    return MouseRegion(
      onEnter: (_) => setState(() => _hoverIndex = _index),
      onExit: (_) => setState(() => _hoverIndex = null),
      child: Container(
        width: _fixedWidth,
        constraints: const BoxConstraints(minHeight: 36),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: const Color(0xFF232326), borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.white24)),
        child: _hoverIndex == _index && names.isNotEmpty
            ? Text('범위: $names', style: const TextStyle(color: Colors.white60), maxLines: 1, overflow: TextOverflow.ellipsis)
            : Text(label, style: const TextStyle(color: Colors.white70), maxLines: 1, overflow: TextOverflow.ellipsis),
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
            child: const Center(child: Icon(Icons.settings, color: Colors.white, size: 22)),
            ),
          ),
        ),
    );
  }
}

class _ExamSettingsDialog extends StatefulWidget {
  const _ExamSettingsDialog();
  @override
  State<_ExamSettingsDialog> createState() => _ExamSettingsDialogState();
}

class _ExamSettingsDialogState extends State<_ExamSettingsDialog> {
  late double _speed;
  late Color _color;
  String _effect = 'glow';
  double _h = 0, _s = 0, _v = 0; // HSV for fine tuning

  @override
  void initState() {
    super.initState();
    _speed = ExamModeService.instance.speed.value;
    _color = ExamModeService.instance.indicatorColor.value;
    _effect = ExamModeService.instance.effect.value;
    _fromColor(_color);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: const Text('시험기간 설정', style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('인디케이터 색상', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 6),
            // 통일된 카드 스타일: 팔레트 + 컬러 원형 + 밝기(HSV) 슬라이더
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: const Color(0xFF232326), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white24)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // HSL 색상 원형 피커(간단 구현): 원형 내부 좌표를 H(각도), S(반지름)로 변환
                GestureDetector(
                  onPanDown: (d) => _pickFromWheel(context, d.localPosition),
                  onPanUpdate: (d) => _pickFromWheel(context, d.localPosition),
                  child: ClipOval(
                    child: CustomPaint(
                      size: const Size(180, 180),
                      painter: _ColorWheelPainter(),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                // 팔레트 (추천 색)
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final col in const [
                    Color(0xFFE53935), Color(0xFFEF5350), Color(0xFFFF7043), Color(0xFFFFB74D),
                    Color(0xFF64B5F6), Color(0xFF1E88E5), Color(0xFF1976D2), Color(0xFF1565C0),
                    Color(0xFF81C784), Color(0xFF43A047), Color(0xFF26A69A), Color(0xFF009688),
                    Color(0xFFBA68C8), Color(0xFF8E24AA), Color(0xFF5E35B1),
                  ])
                    InkWell(
                      onTap: () { setState(() { _color = col; _fromColor(col); ExamModeService.instance.setIndicatorColor(col); }); },
                      borderRadius: BorderRadius.circular(15),
                      child: Container(width: 24, height: 24, decoration: BoxDecoration(color: col, shape: BoxShape.circle, border: Border.all(color: Colors.white24)))
                    ),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  Container(width: 30, height: 30, decoration: BoxDecoration(color: _color, shape: BoxShape.circle)),
                  const SizedBox(width: 10),
                  Expanded(child: Text('#${_color.value.toRadixString(16).padLeft(8,'0')}', style: const TextStyle(color: Colors.white54))),
                ]),
                const SizedBox(height: 10),
                _slider('H', _h, 0, 360, (v){ setState(() { _h = v; _applyHSV(); }); }),
                _slider('S', _s, 0, 1, (v){ setState(() { _s = v; _applyHSV(); }); }),
                _slider('B', _v, 0, 1, (v){ setState(() { _v = v; _applyHSV(); }); }),
              ]),
            ),
            const SizedBox(height: 12),
            const Text('효과', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 6),
            DropdownButtonHideUnderline(
              child: Container(
                decoration: BoxDecoration(border: Border.all(color: Colors.white24), borderRadius: BorderRadius.circular(6)),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: DropdownButton<String>(
                  value: _effect,
                  dropdownColor: const Color(0xFF1F1F1F),
                  style: const TextStyle(color: Colors.white),
                  items: const [
                    DropdownMenuItem(value: 'glow', child: Text('Glow')),
                    DropdownMenuItem(value: 'solid', child: Text('Solid')),
                    DropdownMenuItem(value: 'breath', child: Text('Breath')),
                  ],
                  onChanged: (v) => setState(() => _effect = v ?? 'glow'),
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Text('속도', style: TextStyle(color: Colors.white70)),
            Slider(value: _speed, min: 1.0, max: 30.0, divisions: 290, onChanged: (v) async {
              setState(() => _speed = v);
              // 즉시 반영: 저장 없이도 미리보기 되도록 서비스에 반영
              await ExamModeService.instance.setSpeed(v);
            }),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('닫기', style: TextStyle(color: Colors.white70))),
        FilledButton(
          onPressed: () async {
            await ExamModeService.instance.setIndicatorColor(_color);
            await ExamModeService.instance.setSpeed(_speed);
            await ExamModeService.instance.setEffect(_effect);
            if (mounted) Navigator.of(context).pop();
          },
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
          child: const Text('저장'),
        ),
      ],
    );
  }

  // 공통 슬라이더 위젯
  Widget _slider(String label, double value, double min, double max, ValueChanged<double> onChanged) {
    return Row(children: [
      SizedBox(width: 14, child: Text(label, style: const TextStyle(color: Colors.white54))),
      Expanded(child: Slider(value: value, min: min, max: max, onChanged: onChanged)),
    ]);
  }

  void _fromColor(Color c) {
    final r = c.red / 255.0, g = c.green / 255.0, b = c.blue / 255.0;
    final double maxv = [r,g,b].reduce((a,b)=> a>b?a:b);
    final double minv = [r,g,b].reduce((a,b)=> a<b?a:b);
    final delta = maxv - minv;
    double h = 0.0;
    if (delta != 0) {
      if (maxv == r) h = 60 * (((g-b)/delta) % 6);
      else if (maxv == g) h = 60 * (((b-r)/delta) + 2);
      else h = 60 * (((r-g)/delta) + 4);
    }
    if (h < 0) h += 360;
    final double s = maxv == 0.0 ? 0.0 : (delta / maxv);
    setState(() { _h = h; _s = s; _v = maxv; });
  }

  void _applyHSV() {
    final c = _hsvToColor(_h, _s, _v);
    _color = c;
    // 즉시 미리보기 반영
    ExamModeService.instance.setIndicatorColor(_color);
  }

  Color _hsvToColor(double h, double s, double v) {
    final c = v * s;
    final x = c * (1 - ((h / 60) % 2 - 1).abs());
    final m = v - c;
    double r=0,g=0,b=0;
    if (h < 60) { r=c; g=x; b=0; }
    else if (h < 120) { r=x; g=c; b=0; }
    else if (h < 180) { r=0; g=c; b=x; }
    else if (h < 240) { r=0; g=x; b=c; }
    else if (h < 300) { r=x; g=0; b=c; }
    else { r=c; g=0; b=x; }
    return Color.fromARGB(255, ((r+m)*255).round(), ((g+m)*255).round(), ((b+m)*255).round());
  }

  void _pickFromWheel(BuildContext context, Offset local) {
    // 기준 원: 180x180, 중심 (90,90)
    const double size = 180;
    const double radius = size / 2;
    final Offset center = const Offset(radius, radius);
    final Offset v = local - center;
    double r = v.distance;
    if (r > radius) r = radius;
    // 각도(라디안) → 0..360
    double theta = math.atan2(v.dy, v.dx); // -pi..pi
    double deg = theta * 180 / math.pi;
    if (deg < 0) deg += 360;
    setState(() {
      _h = deg;         // 0..360
      _s = (r / radius).clamp(0.0, 1.0);
      _applyHSV();
    });
  }
}

class _ColorWheelPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final double radius = size.shortestSide / 2;
    final Offset center = Offset(size.width / 2, size.height / 2);
    // Shader 기반 그리기(더 매끈한 경계)
    // FragmentShader 없이도 각도/반경 보간 느낌을 만들기 위해 스윕 그라디언트와 방사형 그라디언트를 합성
    // 1) 바탕: 흰색→투명(중심) + 바깥쪽 색 → 투명(내부) 혼합
    final Rect circle = Rect.fromCircle(center: center, radius: radius);
    // 바깥쪽 색상 스윕(채도=1, 명도=1)
    final SweepGradient sweep = const SweepGradient(
      colors: [
        Colors.red, Color(0xFFFF00FF), Colors.blue, Colors.cyan, Colors.green, Colors.yellow, Colors.red,
      ],
      stops: [0.0, 1/6, 2/6, 3/6, 4/6, 5/6, 1.0],
    );
    // 반径 방향으로 채도 보정: 중심은 흰색, 바깥은 색
    final RadialGradient radial = const RadialGradient(colors: [Colors.white, Colors.transparent], stops: [0.0, 1.0]);
    final Paint paint = Paint()..isAntiAlias = true;
    // 먼저 sweep 채색
    canvas.save();
    canvas.clipPath(Path()..addOval(circle));
    final Paint pSweep = Paint()
      ..isAntiAlias = true
      ..shader = sweep.createShader(circle);
    canvas.drawCircle(center, radius, pSweep);
    // 중심 밝기 보정(흰색 → 투명)
    final Paint pRadial = Paint()
      ..isAntiAlias = true
      ..blendMode = BlendMode.srcOver
      ..shader = radial.createShader(circle);
    canvas.drawCircle(center, radius, pRadial);
    canvas.restore();
    // 외곽 라인
    final border = Paint()
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true
      ..strokeWidth = 1
      ..color = Colors.white24;
    canvas.drawPath(Path()..addOval(Rect.fromCircle(center: center, radius: radius)), border);
  }

  static Color _hsvToColorStatic(double h, double s, double v) {
    final c = v * s;
    final x = c * (1 - ((h / 60) % 2 - 1).abs());
    final m = v - c;
    double r=0,g=0,b=0;
    if (h < 60) { r=c; g=x; b=0; }
    else if (h < 120) { r=x; g=c; b=0; }
    else if (h < 180) { r=0; g=c; b=x; }
    else if (h < 240) { r=0; g=x; b=c; }
    else if (h < 300) { r=x; g=0; b=c; }
    else { r=c; g=0; b=x; }
    return Color.fromARGB(255, ((r+m)*255).round(), ((g+m)*255).round(), ((b+m)*255).round());
  }

  @override
  bool shouldRepaint(covariant _ColorWheelPainter oldDelegate) => false;
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

class _ExamScheduleDialog extends StatefulWidget {
  const _ExamScheduleDialog();
  @override
  State<_ExamScheduleDialog> createState() => _ExamScheduleDialogState();
}

class _ExamScheduleDialogState extends State<_ExamScheduleDialog> {
  // 다이얼로그 성능: reassemble 방지를 위해 Key 유지, RepaintBoundary 적용
  final Key _contentKey = const ValueKey('exam-dialog-content');
  // 과정별 학년 필터: 'M1','M2','M3','H1','H2','H3'
  final Set<String> _gradeFilter = <String>{};
  final GlobalKey<_ExamScheduleWizardState> _middleKey = GlobalKey<_ExamScheduleWizardState>();
  final GlobalKey<_ExamScheduleWizardState> _highKey = GlobalKey<_ExamScheduleWizardState>();
  static const String _kGradeFilterKey = 'exam_dialog_grade_filter';

  Future<void> _openGradeFilterDialog(BuildContext context) async {
    await showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctxSB, setSB) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1F1F1F),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            title: const Text('학년 선택', style: TextStyle(color: Colors.white)),
            content: SizedBox(
              width: 420,
              child: Wrap(
                spacing: 10,
                runSpacing: 8,
                children: const [
                  ['중1','M1'], ['중2','M2'], ['중3','M3'],
                  ['고1','H1'], ['고2','H2'], ['고3','H3'],
                ].map((pair) {
                  // pair[0]: label, pair[1]: key
                  return pair;
                }).toList().map((pair) {
                  final String label = pair[0] as String;
                  final String key = pair[1] as String;
                  final bool selected = _gradeFilter.contains(key);
                  return FilterChip(
                    label: Text(label),
                    selected: selected,
                    onSelected: (val) {
                      setSB(() {
                        setState(() {
                          if (val) {
                            _gradeFilter.add(key);
                          } else {
                            _gradeFilter.remove(key);
                          }
                        });
                      });
                    },
                    backgroundColor: const Color(0xFF232326),
                    selectedColor: const Color(0xFF2A2A2A),
                    labelStyle: TextStyle(color: selected ? Colors.white : Colors.white70),
                    side: BorderSide(color: selected ? const Color(0xFF1976D2) : Colors.white24, width: selected ? 1.6 : 1.0),
                    showCheckmark: true,
                    checkmarkColor: const Color(0xFF1976D2),
                  );
                }).toList(),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  // persist selection
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setStringList(_kGradeFilterKey, _gradeFilter.toList());
                  // ignore: avoid_print
                  print('[GRADE_FILTER][save] ${_gradeFilter.toList()}');
                  if (mounted) setState(() {});
                  Navigator.of(ctxSB).pop();
                },
                child: const Text('닫기', style: TextStyle(color: Colors.white70)),
              ),
            ],
          );
        });
      },
    );
  }

  @override
  void initState() {
    super.initState();
    // restore grade filter
    SharedPreferences.getInstance().then((prefs) {
      final list = prefs.getStringList(_kGradeFilterKey) ?? const <String>[];
      if (list.isNotEmpty && mounted) {
        setState(() {
          _gradeFilter
            ..clear()
            ..addAll(list);
        });
        // ignore: avoid_print
        print('[GRADE_FILTER][load] $list');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final students = DataManager.instance.students;
    // 중학교 → 고등학교 순, 같은 과정 내에서는 학교명 가나다순, 학년은 저학년→고학년
    int levelRank(EducationLevel l){
      if (l == EducationLevel.middle) return 0; // 중
      if (l == EducationLevel.high) return 1;   // 고
      return 2; // 그 외는 뒤로
    }
    // 중/고생만 대상으로 중복 제거 (같은 학교/학년 1회만)
    final Set<String> seen = {};
    final List<Map<String, dynamic>> items = [];
    for (final s in students) {
      final level = s.student.educationLevel;
      if (level == EducationLevel.elementary) continue; // 초등 제외
      final school = s.student.school.trim();
      final grade = s.student.grade;
      final key = '${level.index}|$school|$grade';
      if (seen.contains(key)) continue;
      seen.add(key);
      items.add({'school': school, 'level': level, 'grade': grade});
    }
    items.sort((a,b){
      final lr = levelRank(a['level'] as EducationLevel).compareTo(levelRank(b['level'] as EducationLevel));
      if (lr != 0) return lr;
      final sr = (a['school'] as String).compareTo(b['school'] as String);
      if (sr != 0) return sr;
      return (a['grade'] as int).compareTo(b['grade'] as int);
    });
    String _prefix(EducationLevel l) => l == EducationLevel.middle ? 'M' : (l == EducationLevel.high ? 'H' : '');
    final List<Map<String, dynamic>> middle = items.where((m) => m['level'] == EducationLevel.middle).toList();
    final List<Map<String, dynamic>> high = items.where((m) => m['level'] == EducationLevel.high).toList();
    String _labelOf(Map<String, dynamic> m) {
      final school = m['school'] as String; final grade = m['grade'] as int; return grade > 0 ? '$school ${grade}학년' : school;
    }
    final List<String> schoolGradeMiddle = middle.where((m) {
      // 아무 학년도 선택하지 않으면 아무 항목도 표시하지 않음
      if (_gradeFilter.isEmpty) return false;
      final level = m['level'] as EducationLevel;
      final grade = m['grade'] as int;
      final key = '${_prefix(level)}$grade';
      return _gradeFilter.contains(key);
    }).map((m){
      return _labelOf(m);
    }).toList();
    final List<String> schoolGradeHigh = high.where((m) {
      if (_gradeFilter.isEmpty) return false;
      final level = m['level'] as EducationLevel; final grade = m['grade'] as int; final key = '${_prefix(level)}$grade';
      return _gradeFilter.contains(key);
    }).map((m){ return _labelOf(m); }).toList();

    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: Row(
        children: [
          const Text('시험 일정', style: TextStyle(color: Colors.white)),
          const Spacer(),
          TextButton.icon(
            onPressed: () => _openGradeFilterDialog(context),
            icon: const Icon(Icons.grade, size: 18),
            label: const Text('학년'),
            style: TextButton.styleFrom(
              foregroundColor: Colors.white70,
              backgroundColor: Colors.white12,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            ),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: () => _openSubjectListDialog(context),
            icon: const Icon(Icons.menu_book, size: 18),
            label: const Text('과목'),
            style: TextButton.styleFrom(
              foregroundColor: Colors.white70,
              backgroundColor: Colors.white12,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            ),
          ),
        ],
      ),
      content: RepaintBoundary(
        key: _contentKey,
        child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.60,
        width: 1360,
        child: Stack(
          children: [
            // 프리로드 결과를 위저드에 주입 (첫 프레임 직후 1회)
            Builder(builder: (_) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                final mid = _middleKey.currentState;
                if (mid != null) {
                  _preloadedSavedBySg.forEach((k, v) { if (schoolGradeMiddle.contains(k)) mid._savedBySchoolGrade[k] = Map<DateTime, List<String>>.from(v); });
                  _preloadedRangesBySg.forEach((k, v) { if (schoolGradeMiddle.contains(k)) mid._rangesBySchoolGrade[k] = Map<DateTime, String>.from(v); });
                  mid.setState(() {});
                }
                final hi = _highKey.currentState;
                if (hi != null) {
                  _preloadedSavedBySg.forEach((k, v) { if (schoolGradeHigh.contains(k)) hi._savedBySchoolGrade[k] = Map<DateTime, List<String>>.from(v); });
                  _preloadedRangesBySg.forEach((k, v) { if (schoolGradeHigh.contains(k)) hi._rangesBySchoolGrade[k] = Map<DateTime, String>.from(v); });
                  hi.setState(() {});
                }
              });
              return const SizedBox.shrink();
            }),
            Row(
              children: [
                Expanded(child: _ExamScheduleWizard(key: _middleKey, schoolGrade: schoolGradeMiddle, level: EducationLevel.middle)),
                const SizedBox(width: 12),
                Expanded(child: _ExamScheduleWizard(key: _highKey, schoolGrade: schoolGradeHigh, level: EducationLevel.high)),
              ],
            ),
            // 외부 오버레이: 호버된 행의 날짜 요약 표시
            Positioned(
              right: 8,
              top: 40,
              child: Builder(builder: (context) {
                final st = _middleKey.currentState ?? _highKey.currentState;
                if (st == null) return const SizedBox.shrink();
                final sg = st._hoveredSchoolGrade;
                if (sg == null) return const SizedBox.shrink();
                final picked = st._selectedDaysBySchoolGrade[sg] ?? <DateTime>{};
                final label = picked.isEmpty ? '날짜 선택 없음' : (picked.toList()..sort()).map((d)=>'${d.month}.${d.day}').join(' · ');
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(color: const Color(0xFF232326), borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.white24)),
                  child: Text(label, style: const TextStyle(color: Colors.white60, fontSize: 13)),
                );
              }),
            ),
          ],
        ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            // 1) 상태 스냅샷(복사) → 2) 즉시 닫기 → 3) 백그라운드 저장
            Map<String, Map<DateTime, List<String>>> snapshotSaved(_ExamScheduleWizardState? st) {
              if (st == null) return const {};
              return {
                for (final e in st._savedBySchoolGrade.entries)
                  e.key: {
                    for (final e2 in e.value.entries)
                      DateTime(e2.key.year, e2.key.month, e2.key.day): List<String>.from(e2.value)
                  }
              };
            }
            Map<String, Map<DateTime, String>> snapshotRanges(_ExamScheduleWizardState? st) {
              if (st == null) return const {};
              return {
                for (final e in st._rangesBySchoolGrade.entries)
                  e.key: {
                    for (final e2 in e.value.entries)
                      DateTime(e2.key.year, e2.key.month, e2.key.day): e2.value
                  }
              };
            }
            Map<String, Set<DateTime>> snapshotDays(_ExamScheduleWizardState? st) {
              if (st == null) return const {};
              return {
                for (final e in st._selectedDaysBySchoolGrade.entries)
                  e.key: e.value.map((d) => DateTime(d.year, d.month, d.day)).toSet()
              };
            }

            final midSaved = snapshotSaved(_middleKey.currentState);
            final midRanges = snapshotRanges(_middleKey.currentState);
            final midDays = snapshotDays(_middleKey.currentState);
            final hiSaved = snapshotSaved(_highKey.currentState);
            final hiRanges = snapshotRanges(_highKey.currentState);
            final hiDays = snapshotDays(_highKey.currentState);

            if (mounted) Navigator.of(context).pop();

            Future<void> saveFromSnapshot({
              required Map<String, Map<DateTime, List<String>>> saved,
              required Map<String, Map<DateTime, String>> ranges,
              required Map<String, Set<DateTime>> days,
              required EducationLevel level,
            }) async {
              DateTime? lastDate;
              for (final sg in saved.keys) {
                final idx = sg.lastIndexOf(' ');
                final schoolName = idx > 0 ? sg.substring(0, idx) : sg;
                final gradeText = idx > 0 ? sg.substring(idx + 1) : '';
                final gradeNum = int.tryParse(gradeText.replaceAll('학년', '')) ?? 0;
                final titles = saved[sg] ?? const <DateTime, List<String>>{};
                final rng = ranges[sg] ?? const <DateTime, String>{};
                await DataManager.instance.saveExamFor(schoolName, level, gradeNum, titles, rng);
                final dset = days[sg] ?? <DateTime>{};
                if (dset.isNotEmpty) {
                  await DataManager.instance.saveExamDays(schoolName, level, gradeNum, dset);
                  final maxDay = dset.reduce((a, b) => a.isAfter(b) ? a : b);
                  if (lastDate == null || maxDay.isAfter(lastDate)) lastDate = maxDay;
                }
              }
              if (lastDate != null) {
                final until = DateTime(lastDate!.year, lastDate!.month, lastDate!.day, 23, 59, 59);
                await ExamModeService.instance.setUntil(until);
                await ExamModeService.instance.setOn(true);
              }
            }

            // 백그라운드 저장(에러는 콘솔에만 로그)
            unawaited(Future(() async {
              try { await saveFromSnapshot(saved: midSaved, ranges: midRanges, days: midDays, level: EducationLevel.middle); } catch (_) {}
              try { await saveFromSnapshot(saved: hiSaved, ranges: hiRanges, days: hiDays, level: EducationLevel.high); } catch (_) {}
            }));
          },
          child: const Text('닫기', style: TextStyle(color: Colors.white70)),
        )
      ],
    );
  }
}

Future<void> _openSubjectListDialog(BuildContext context) async {
  await showDialog(
    context: context,
    barrierDismissible: true,
    builder: (ctx) {
      return StatefulBuilder(builder: (ctxSB, setSB) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1F1F1F),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          title: Row(
            children: [
              const Text('시험명', style: TextStyle(color: Colors.white)),
              const Spacer(),
              TextButton.icon(
                onPressed: () async {
                  final name = await _openExamNameAddDialog(ctxSB);
                  if (name != null && name.trim().isNotEmpty) {
                    final trimmed = name.trim();
                    final list = [..._examNames.value];
                    if (!list.contains(trimmed)) {
                      list.add(trimmed);
                      _examNames.value = list;
                      await _saveExamMetaPrefs();
                    }
                  }
                },
                icon: const Icon(Icons.add, size: 18),
                label: const Text('추가'),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white70,
                  backgroundColor: Colors.white12,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 560,
            height: 440,
            child: ValueListenableBuilder<List<String>>(
              valueListenable: _examNames,
              builder: (context, items, _) {
                if (items.isEmpty) {
                  return const Center(child: Text('등록된 시험명이 없습니다. 우측 상단에서 추가하세요.', style: TextStyle(color: Colors.white54)));
                }
                final sorted = [...items]..sort();
                return ListView.separated(
                  itemCount: sorted.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white12),
                  itemBuilder: (c, i) {
                    final name = sorted[i];
                    final assigned = _examAssignmentByName[name] ?? <String, Set<int>>{};
                    // 학교 키에서 학교명만 추출하여 나열
                    List<String> schools = assigned.keys.map((k) {
                      final idx = k.indexOf('|');
                      return idx >= 0 ? k.substring(idx + 1) : k;
                    }).toList()
                      ..sort();
                    final rightText = schools.isEmpty ? '' : schools.join(' · ');
                    return ListTile(
                      title: Text(name, style: const TextStyle(color: Colors.white, fontSize: 20)),
                      subtitle: null,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                        width: 260,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: Text(
                            rightText,
                            textAlign: TextAlign.right,
                            overflow: TextOverflow.ellipsis,
                            maxLines: 2,
                                style: const TextStyle(color: Colors.white54, fontSize: 14),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            tooltip: '삭제',
                            onPressed: () {
                              setSB(() {
                                final list = [..._examNames.value]..remove(name);
                                _examNames.value = list;
                                _examAssignmentByName.remove(name);
                                _saveExamMetaPrefs();
                              });
                            },
                            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                          ),
                        ],
                      ),
                      onTap: () async {
                        await _openSchoolGradeMultiSelectDialog(context, name);
                        await _saveExamMetaPrefs();
                        setSB(() {}); // 선택 결과 반영
                      },
                    );
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctxSB).pop(),
              child: const Text('닫기', style: TextStyle(color: Colors.white70)),
            ),
          ],
        );
      });
    },
  );
}

Future<String?> _openExamNameAddDialog(BuildContext context) async {
  return showDialog<String>(
    context: context,
    builder: (ctx) {
      final ctrl = TextEditingController();
      return AlertDialog(
        backgroundColor: const Color(0xFF1F1F1F),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('시험명 추가', style: TextStyle(color: Colors.white)),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: ctrl,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              hintText: '예: 중간고사 수학',
              hintStyle: TextStyle(color: Colors.white38),
              enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
              focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('취소', style: TextStyle(color: Colors.white70))),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
            child: const Text('추가'),
          ),
        ],
      );
    },
  );
}

Future<void> _openSchoolGradeMultiSelectDialog(BuildContext context, String examName) async {
  // 학생 데이터로부터 학교/레벨/학년 정보를 취합
  final students = DataManager.instance.students;
  int levelRank(EducationLevel l){
    if (l == EducationLevel.middle) return 0; // 중
    if (l == EducationLevel.high) return 1;   // 고
    return 2; // 그 외는 뒤로
  }
  // schoolKey = '${level.index}|$school'
  final Map<String, Map<String, dynamic>> metaBySchool = <String, Map<String, dynamic>>{};
  for (final s in students) {
    final level = s.student.educationLevel;
    if (level == EducationLevel.elementary) continue; // 초등 제외
    final school = s.student.school.trim();
    final grade = s.student.grade;
    final key = '${level.index}|$school';
    final meta = metaBySchool.putIfAbsent(key, () => {
      'school': school,
      'level': level,
      'grades': <int>{},
    });
    (meta['grades'] as Set<int>).add(grade);
  }
  // 정렬
  final keys = metaBySchool.keys.toList()
    ..sort((a, b) {
      final ma = metaBySchool[a]!;
      final mb = metaBySchool[b]!;
      final lr = levelRank(ma['level'] as EducationLevel).compareTo(levelRank(mb['level'] as EducationLevel));
      if (lr != 0) return lr;
      return (ma['school'] as String).compareTo(mb['school'] as String);
    });

  // 기존 선택 불러오기
  final Map<String, Set<int>> local = <String, Set<int>>{};
  final existing = _examAssignmentByName[examName] ?? <String, Set<int>>{};
  existing.forEach((k, v) => local[k] = {...v});

  await showDialog(
    context: context,
    barrierDismissible: true,
    builder: (ctx) {
      return StatefulBuilder(builder: (ctxSB, setSB) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1F1F1F),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          title: Text('학교·학년 선택 - $examName', style: const TextStyle(color: Colors.white)),
          content: SizedBox(
            width: 460,
            height: MediaQuery.of(ctxSB).size.height * 0.60,
            child: ListView.separated(
              itemCount: keys.length,
              separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white12),
              itemBuilder: (c, i) {
                final key = keys[i];
                final meta = metaBySchool[key]!;
                final school = meta['school'] as String;
                final level = meta['level'] as EducationLevel;
                final grades = (meta['grades'] as Set<int>).toList()..sort();
                final selected = local[key] ?? <int>{};
                String levelLabel = level == EducationLevel.middle ? '중' : (level == EducationLevel.high ? '고' : '');
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Text('$school${levelLabel.isNotEmpty ? ' ($levelLabel)' : ''}', style: const TextStyle(color: Colors.white, fontSize: 16)),
                      ),
                      Wrap(
                        spacing: 10,
                        runSpacing: 6,
                        children: grades.map((g) {
                          final checked = selected.contains(g);
                          return FilterChip(
                            label: Text('${g}학년'),
                            selected: checked,
                            onSelected: (val) {
                              setSB(() {
                                final set = local.putIfAbsent(key, () => <int>{});
                                if (val) {
                                  set.add(g);
                                } else {
                                  set.remove(g);
                                  if (set.isEmpty) local.remove(key);
                                }
                              });
                            },
                            backgroundColor: const Color(0xFF232326),
                            selectedColor: const Color(0xFF2A2A2A),
                            labelStyle: TextStyle(color: checked ? Colors.white : Colors.white70),
                            side: BorderSide(color: checked ? const Color(0xFF1976D2) : Colors.white24, width: checked ? 1.6 : 1.0),
                            showCheckmark: true,
                            checkmarkColor: const Color(0xFF1976D2),
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('취소', style: TextStyle(color: Colors.white70))),
            FilledButton(
              onPressed: () {
                // 저장 반영
                _examAssignmentByName[examName] = {
                  for (final e in local.entries) e.key: {...e.value}
                };
                Navigator.of(ctx).pop();
              },
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
              child: const Text('저장'),
            ),
          ],
        );
      });
    },
  );
}

class _ExamScheduleWizard extends StatefulWidget {
  final List<String> schoolGrade;
  final EducationLevel? level;
  const _ExamScheduleWizard({Key? key, required this.schoolGrade, this.level}) : super(key: key);
  @override
  State<_ExamScheduleWizard> createState() => _ExamScheduleWizardState();
}

class _ExamScheduleWizardState extends State<_ExamScheduleWizard> {
  int _step = 0; // 0: 학교/학년 선택, 1: 날짜 다중 선택, 2: 날짜 카드 관리
  String? _selectedSchoolGrade;
  final Set<DateTime> _selectedDays = {};
  final Map<DateTime, List<String>> _titlesByDate = {};
  final TextEditingController _titleCtrl = TextEditingController();
  final Map<String, Map<DateTime, List<String>>> _savedBySchoolGrade = {};
  final Map<String, Set<DateTime>> _selectedDaysBySchoolGrade = {};
  // 날짜별 범위 메모: 학교/학년 → 날짜 → 범위 텍스트
  final Map<String, Map<DateTime, String>> _rangesBySchoolGrade = {};
  // 학교/학년별 추가 범위 배지(시험명: 범위) 임시 표시용
  final Map<String, List<String>> _rangeBadgesBySchoolGrade = {};
  // 리스트 행 호버 상태(날짜 표시용)
  String? _hoveredSchoolGrade;
  // 호버 툴팁 오버레이 상태
  OverlayEntry? _hoverTooltip;
  Offset _hoverTooltipPos = Offset.zero;
  String _hoverTooltipText = '';

  @override
  void dispose() {
    _hideHoverTooltip();
    _titleCtrl.dispose();
    super.dispose();
  }

  void _hideHoverTooltip() {
    try {
      _hoverTooltip?.remove();
    } catch (_) {}
    _hoverTooltip = null;
  }

  void _ensureHoverTooltip(BuildContext context) {
    if (_hoverTooltip != null) return;
    final overlay = Overlay.of(context);
    if (overlay == null) return;
    _hoverTooltip = OverlayEntry(builder: (ctx) {
      return Positioned(
        left: _hoverTooltipPos.dx + 12,
        top: _hoverTooltipPos.dy + 12,
        child: Material(
          color: Colors.transparent,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 280),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF232326),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.white24),
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.24), blurRadius: 10, offset: const Offset(0, 6)),
              ],
            ),
            child: Text(_hoverTooltipText, style: const TextStyle(color: Colors.white70, fontSize: 13)),
          ),
        ),
      );
    });
    overlay.insert(_hoverTooltip!);
  }

  void _updateHoverTooltip(BuildContext context, String text, Offset globalPos) {
    _hoverTooltipText = text;
    _hoverTooltipPos = globalPos;
    _ensureHoverTooltip(context);
    try { _hoverTooltip?.markNeedsBuild(); } catch (_) {}
  }

  String _buildHoverPeriodLabelFor(String schoolGradeKey) {
    // 1) 현재 세션에서 달력으로 선택한 날짜 우선
    final Set<DateTime> sessionPicked = (_selectedDaysBySchoolGrade[schoolGradeKey] ?? <DateTime>{});
    Set<DateTime> picked;
    if (sessionPicked.isNotEmpty) {
      picked = sessionPicked.map((d) => DateTime(d.year, d.month, d.day)).toSet();
    } else {
      // 2) 없으면 DB의 exam_days 사용
      final idx = schoolGradeKey.lastIndexOf(' ');
      final schoolName = idx > 0 ? schoolGradeKey.substring(0, idx) : schoolGradeKey;
      final gradeText = idx > 0 ? schoolGradeKey.substring(idx + 1) : '';
      final gradeNum = int.tryParse(gradeText.replaceAll('학년', '')) ?? 0;
      final level = widget.level ?? EducationLevel.middle;
      picked = DataManager.instance.getExamDaysForSchoolGrade(
        school: schoolName,
        level: level,
        grade: gradeNum,
      );
    }
    if (picked.isEmpty) return '시험기간 : (선택 없음)';
    final dates = picked.toList()..sort();
    final label = dates.map((d) => '${d.month}/${d.day}').join(', ');
    return '시험기간 : $label';
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 620,
      child: RepaintBoundary(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: _buildStep(),
        ),
      ),
    );
  }

  Widget _buildStep() {
    if (_step == 0) {
      return Column(
        key: const ValueKey('step0'),
        mainAxisSize: MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('학교/학년 선택', style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 8),
          // 기존 FutureBuilder 제거: 프리로드/메모리 캐시 주입을 우선 사용
          // (필요 시 외부에서 _preloadExamDialogData 실행 후, 다이얼로그 build 시 주입됨)
          Expanded(
            child: Container(
              decoration: BoxDecoration(color: const Color(0xFF2A2A2A), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white24)),
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: widget.schoolGrade.length,
                separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white12),
                itemBuilder: (context, i) {
                  final item = widget.schoolGrade[i];
                  final partsIdx = item.lastIndexOf(' ');
                  final schoolName = partsIdx > 0 ? item.substring(0, partsIdx) : item;
                  final gradeText = partsIdx > 0 ? item.substring(partsIdx + 1) : '';
                  final isSelectedSchool = _selectedSchoolGrade == item;
                  final saved = _savedBySchoolGrade[item];
                  final int savedCount = saved == null ? 0 : saved.values.fold(0, (p, e) => p + e.length);
                  // 호버 시 날짜선택 다이얼로그에서 선택한 날짜 모두 표시
                  final Set<DateTime> pickedDays = _selectedDaysBySchoolGrade[item] ?? <DateTime>{};
                  final String dateInline = pickedDays.isEmpty
                      ? ''
                      : (pickedDays.toList()..sort())
                          .map((d) => '${d.month}.${d.day}')
                          .join(' · ');
                  // 시험명이 등록된 날짜만 요약으로 표시
                  final namedEntries = (saved ?? {}).entries
                      .where((e) => (e.value).isNotEmpty)
                      .toList()
                    ..sort((a, b) => a.key.compareTo(b.key));
                  // 날짜별 시험명 목록을 배지로 나열하기 위해 평탄화
                  final List<MapEntry<DateTime, String>> named = [];
                  for (final e in namedEntries) {
                    for (final t in e.value) {
                      final tt = t.trim();
                      if (tt.isNotEmpty) named.add(MapEntry(e.key, tt));
                    }
                  }
                  named.sort((a, b) => a.key.compareTo(b.key));
                  // 배지/버튼 상태 계산
                  final Set<String> _distinctNames = named.map((e) => e.value).toSet();
                  final bool _hasMultipleExamNames = _distinctNames.length > 1;
                  final bool _hasSchedule = (saved?.values.any((v) => v.isNotEmpty) ?? false);
                  // 각 날짜별로 범위가 모두 채워진 경우에만 범위 버튼 숨김
                  bool _allRangesCompletedForSaved() {
                    final map = _savedBySchoolGrade[item] ?? const <DateTime, List<String>>{};
                    if (map.isEmpty) return false;
                    for (final entry in map.entries) {
                      final dateKey = DateTime(entry.key.year, entry.key.month, entry.key.day);
                      final names = entry.value;
                      if (names.isEmpty) return false;
                      final hasRange = (_rangesBySchoolGrade[item] ?? const <DateTime, String>{})[dateKey];
                      if (hasRange == null || hasRange.trim().isEmpty) return false;
                    }
                    return true;
                  }
                  final bool _hasRangeForSg = _allRangesCompletedForSaved();
                  return MouseRegion(
                    onEnter: (e) {
                      setState(() => _hoveredSchoolGrade = item);
                      final tip = _buildHoverPeriodLabelFor(item);
                      _updateHoverTooltip(context, tip, e.position);
                    },
                    onHover: (e) {
                      final tip = _buildHoverPeriodLabelFor(item);
                      _updateHoverTooltip(context, tip, e.position);
                    },
                    onExit:  (_) {
                      setState(() => _hoveredSchoolGrade = null);
                      _hideHoverTooltip();
                    },
                    child: Container(
                      padding: EdgeInsets.symmetric(horizontal: 12, vertical: _hasMultipleExamNames ? 16 : 10),
                      child: Row(
                        children: [
                          // 학교 카드(고정 폭)
                          ConstrainedBox(
                            constraints: const BoxConstraints(minWidth: 90, maxWidth: 120),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: () async {
                                // 확인 다이얼로그
                                final confirmed = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) {
                                    return AlertDialog(
                                      backgroundColor: const Color(0xFF1F1F1F),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                      title: const Text('삭제 확인', style: TextStyle(color: Colors.white)),
                                      content: Text('$schoolName $gradeText 데이터를 삭제할까요?', style: const TextStyle(color: Colors.white70)),
                                      actions: [
                                        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('취소', style: TextStyle(color: Colors.white70))),
                                        FilledButton(onPressed: () => Navigator.of(ctx).pop(true), style: FilledButton.styleFrom(backgroundColor: const Color(0xFFD32F2F)), child: const Text('삭제')),
                                      ],
                                    );
                                  },
                                );
                                if (confirmed == true) {
                                  final idx = item.lastIndexOf(' ');
                                  final sch = idx > 0 ? item.substring(0, idx) : item;
                                  final gtext = idx > 0 ? item.substring(idx + 1) : '';
                                  final gnum = int.tryParse(gtext.replaceAll('학년', '')) ?? 0;
                                  final level = widget.level ?? EducationLevel.middle;
                                  await DataManager.instance.deleteExamData(sch, level, gnum);
                                  // 로컬 위저드 상태 및 프리로드 데이터 비우기
                                  setState(() {
                                    _savedBySchoolGrade.remove(item);
                                    _rangesBySchoolGrade.remove(item);
                                    _preloadedSavedBySg.remove(item);
                                    _preloadedRangesBySg.remove(item);
                                    _selectedDaysBySchoolGrade.remove(item);
                                  });
                                }
                              },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: Colors.transparent,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.transparent),
                              ),
                              child: Text(
                                schoolName,
                                style: TextStyle(color: isSelectedSchool ? Colors.white : Colors.white70, fontSize: 16),
                                overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          // 학년(고정 폭)
                          SizedBox(
                            width: 56,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                gradeText,
                                style: TextStyle(color: isSelectedSchool ? Colors.white : Colors.white60, fontSize: 16),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          // 시험/날짜/범위 배지 (고정 순서: 시험명 → 날짜 → 범위)
                          Expanded(
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                // 스켈레톤: 프리로드 결과가 아직 주입되지 않은 초기 1프레임 대비
                                if ((_savedBySchoolGrade.isEmpty && _rangesBySchoolGrade.isEmpty)) ...[
                                  for (int k = 0; k < 3; k++)
                                    Container(
                                      width: 80 + (k * 18),
                                      height: 22,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF2A2A2A),
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(color: Colors.white12),
                                      ),
                                    ),
                                ],
                                // 저장된 일정 기반 배지: 시험명 → 날짜 → 범위
                                // 한 시험의 (시험명, 날짜, 범위)를 세트로 묶어서 한 줄로 유지
                                ...named.map((e) {
                                  final sg = item;
                                final range = _rangesBySchoolGrade[sg]?[DateTime(e.key.year, e.key.month, e.key.day)];
                                  Widget chip(String text, {double fs = 14, bool transparentBorder = false, VoidCallback? onTap}) {
                                    final core = Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF2A2A2A),
                                      borderRadius: BorderRadius.circular(6),
                                        border: Border.all(color: transparentBorder ? Colors.transparent : Colors.white24),
                                      ),
                                      child: Text(text, style: TextStyle(color: Colors.white70, fontSize: fs)),
                                    );
                                    return onTap == null ? core : InkWell(onTap: onTap, borderRadius: BorderRadius.circular(6), child: core);
                                  }
                                  final dateKey = DateTime(e.key.year, e.key.month, e.key.day);
                                  return Row(mainAxisSize: MainAxisSize.min, children: [
                                    // 시험명 배지 클릭: 해당 날짜의 시험명 편집
                                    chip(e.value, onTap: () async {
                                      final edited = await _openDateSelectAndSaveDialog(context, [dateKey], schoolGradeLabel: sg);
                                      if (edited != null && edited.isNotEmpty) {
                                        setState(() {
                                          final map = _savedBySchoolGrade[sg] ?? <DateTime, List<String>>{};
                                          map[dateKey] = edited[dateKey] ?? <String>[];
                                          _savedBySchoolGrade[sg] = map;
                                        });
                                      }
                                    }),
                                    const SizedBox(width: 6),
                                    // 날짜 배지 클릭: 동일하게 해당 날짜의 시험명 편집 다이얼로그로 연결
                                    chip('${e.key.month}.${e.key.day}', fs: 13, onTap: () async {
                                      final edited = await _openDateSelectAndSaveDialog(context, [dateKey], schoolGradeLabel: sg);
                                      if (edited != null && edited.isNotEmpty) {
                                        setState(() {
                                          final map = _savedBySchoolGrade[sg] ?? <DateTime, List<String>>{};
                                          map[dateKey] = edited[dateKey] ?? <String>[];
                                          _savedBySchoolGrade[sg] = map;
                                        });
                                      }
                                    }),
                                    if (range != null && range.trim().isNotEmpty) ...[
                                      const SizedBox(width: 6),
                                      // 범위 배지 클릭: 해당 날짜만 범위 편집
                                      chip(range, fs: 13, transparentBorder: true, onTap: () async {
                                        final single = <DateTime, List<String>>{ dateKey: (_savedBySchoolGrade[sg]?[dateKey] ?? <String>[]) };
                                        final newRangeMap = await _openRangeEditDialog(context, sg, single);
                                        if (newRangeMap != null) {
                                          setState(() {
                                            final map = _rangesBySchoolGrade[sg] ?? <DateTime, String>{};
                                            final r = newRangeMap[dateKey];
                                            if (r != null) map[dateKey] = r;
                                            _rangesBySchoolGrade[sg] = map;
                                          });
                                        }
                                      }),
                                    ],
                                  ]);
                              }).toList(),
                                // 범위만 추가된 임시 배지: "이름: 범위" → 시험명 → (날짜 없음) → 범위
                                ...(_rangeBadgesBySchoolGrade[item] ?? const <String>[]).map((text) {
                                  final idx = text.indexOf(':');
                                  String name = text;
                                  String range = '';
                                  if (idx >= 0) {
                                    name = text.substring(0, idx).trim();
                                    range = text.substring(idx + 1).trim();
                                  }
                                  Widget chip(String t, {double fs = 14, bool transparentBorder = false}) => Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                      color: const Color(0xFF2A2A2A),
                                borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: transparentBorder ? Colors.transparent : Colors.white24),
                                    ),
                                    child: Text(t, style: TextStyle(color: Colors.white70, fontSize: fs)),
                                  );
                                  return Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      chip(name),
                                      if (range.isNotEmpty) ...[
                                        const SizedBox(width: 6),
                                        chip(range, fs: 13, transparentBorder: true),
                                      ],
                                    ],
                                  );
                                }).toList(),
                              ],
                            ),
                          ),
                          // 내부 표시 제거: 외부 오버레이로 대체 예정
                          if (!_hasSchedule) ...[
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: () {
                              setState(() { _selectedSchoolGrade = item; _selectedDays.clear(); _step = 1; });
                            },
                            style: TextButton.styleFrom(foregroundColor: Colors.white70, backgroundColor: Colors.white12, padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6)),
                            child: const Text('일정'),
                          ),
                          ],
                          if (!_hasRangeForSg) ...[
                          const SizedBox(width: 6),
                          TextButton(
                            onPressed: () async {
                              setState(() { _selectedSchoolGrade = item; });
                              final savedMap = _savedBySchoolGrade[item] ?? {};
                              final hasNames = savedMap.values.any((v) => v.isNotEmpty);
                              if (hasNames) {
                                  final res = await _openRangeEditDialog(context, item, savedMap);
                                  if (res != null) {
                                    setState(() {
                                      _rangesBySchoolGrade[item] = res;
                                      // ignore: avoid_print
                                      print('[RANGE_EDIT][apply] schoolGrade=$item, keys=${res.keys.toList()}');
                                    });
                                  }
                              } else {
                                await _openRangeAddDialog(context);
                              }
                            },
                            style: TextButton.styleFrom(foregroundColor: Colors.white70, backgroundColor: Colors.white12, padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6)),
                            child: const Text('범위'),
                          ),
                          ],
                        ],
                      ),
                      ),
                    );
                },
              ),
            ),
          ),
          // 하단 닫기 버튼은 상위 다이얼로그에서만 제공 (여기서는 제거)
        ],
      );
    }
    if (_step == 1) {
      // 일정탭의 _MonthlyCalendar 스타일 차용
      final now = DateTime.now();
      DateTime _displayMonth = DateTime(now.year, now.month, 1);
      return StatefulBuilder(builder: (context, setStateSB) {
        List<Widget> buildCalendar(DateTime month) {
          final first = DateTime(month.year, month.month, 1);
          final firstWeekday = first.weekday; // 1..7 (Mon..Sun)
          final leading = (firstWeekday - 1) % 7;
          final totalCells = 42; // 6주 그리드
          final cells = List<DateTime>.generate(totalCells, (i) {
            final dayOffset = i - leading;
            return DateTime(month.year, month.month, 1 + dayOffset);
          });

          TextStyle numStyle(bool current) => TextStyle(color: current ? Colors.white70 : Colors.white30, fontSize: 21, fontWeight: current ? FontWeight.w700 : FontWeight.w600);
          return [
            Row(
              children: [
                IconButton(onPressed: () => setStateSB(() => _displayMonth = DateTime(_displayMonth.year, _displayMonth.month - 1, 1)), icon: const Icon(Icons.chevron_left, color: Colors.white70)),
                Expanded(child: GestureDetector(
                  onTap: () async {
                    // 간단 월/년 선택 생략
                  },
                  child: Center(child: Text('${_displayMonth.year}년 ${_displayMonth.month}월', style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700))),
                )),
                IconButton(onPressed: () => setStateSB(() => _displayMonth = DateTime(_displayMonth.year, _displayMonth.month + 1, 1)), icon: const Icon(Icons.chevron_right, color: Colors.white70)),
              ],
            ),
            const SizedBox(height: 8),
            Row(children: const [
              Expanded(child: Center(child: Text('월', style: TextStyle(color: Colors.white60, fontSize: 15, fontWeight: FontWeight.w600)))),
              Expanded(child: Center(child: Text('화', style: TextStyle(color: Colors.white60, fontSize: 15, fontWeight: FontWeight.w600)))),
              Expanded(child: Center(child: Text('수', style: TextStyle(color: Colors.white60, fontSize: 15, fontWeight: FontWeight.w600)))),
              Expanded(child: Center(child: Text('목', style: TextStyle(color: Colors.white60, fontSize: 15, fontWeight: FontWeight.w600)))),
              Expanded(child: Center(child: Text('금', style: TextStyle(color: Colors.white60, fontSize: 15, fontWeight: FontWeight.w600)))),
              Expanded(child: Center(child: Text('토', style: TextStyle(color: Color(0xFF64A6DD), fontSize: 15, fontWeight: FontWeight.w600)))),
              Expanded(child: Center(child: Text('일', style: TextStyle(color: Color(0xFFEF6E6E), fontSize: 15, fontWeight: FontWeight.w600)))),
            ]),
            const SizedBox(height: 8),
            Expanded(
              child: GridView.builder(
                padding: EdgeInsets.zero,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 7,
                  mainAxisSpacing: 6,
                  crossAxisSpacing: 6,
                ),
                itemCount: totalCells,
                itemBuilder: (context, i) {
                  final d = cells[i];
                  final isCurrentMonth = d.month == _displayMonth.month;
                  final key = DateTime(d.year, d.month, d.day);
                  final sel = _selectedDays.contains(key);
                  return GestureDetector(
                    onTap: () {
                      setStateSB(() {
                        if (sel) {
                          _selectedDays.remove(key);
                        } else {
                          _selectedDays.add(key);
                        }
                      });
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      decoration: BoxDecoration(
                        color: sel ? const Color(0xFF1976D2).withOpacity(0.22) : Colors.transparent,
                        border: Border.all(color: sel ? const Color(0xFF1976D2) : Colors.white12, width: sel ? 1.6 : 1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.all(8),
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: Text('${d.day}', style: numStyle(isCurrentMonth)),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => setState(() => _step = 0),
                  style: TextButton.styleFrom(foregroundColor: Colors.white70),
                  child: const Text('뒤로'),
                ),
                if (_selectedDays.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () async {
                      final list = _selectedDays.toList()..sort();
                      final Map<DateTime, List<String>>? added = await _openDateSelectAndSaveDialog(context, list, schoolGradeLabel: _selectedSchoolGrade);
                      if (added != null) {
                        setState(() {
                          // 현재 선택한 학교-학년의 저장 정보에 합치기
                          final sg = _selectedSchoolGrade;
                          if (sg != null) {
                            final existing = _savedBySchoolGrade[sg] ?? {};
                            added.forEach((k, v) {
                              final cur = existing[k] ?? [];
                              existing[k] = [...cur, ...v];
                              final curLocal = _titlesByDate[k] ?? [];
                              _titlesByDate[k] = [...curLocal, ...v];
                            });
                            _savedBySchoolGrade[sg] = existing;
                            _selectedDaysBySchoolGrade[sg] = list.toSet();

                            // 범위-먼저 추가된 임시 배지와 새 일정 매칭: 같은 시험명에 범위를 결합하고 임시 배지는 제거
                            final pending = _rangeBadgesBySchoolGrade[sg] ?? <String>[];
                            if (pending.isNotEmpty) {
                              // ignore: avoid_print
                              print('[RANGE_MATCH] pending before match: $pending');
                              final Map<String, String> rangeByName = {};
                              for (final entry in pending) {
                                final idx = entry.indexOf(':');
                                if (idx > 0) {
                                  final name = entry.substring(0, idx).trim();
                                  final range = entry.substring(idx + 1).trim();
                                  if (name.isNotEmpty && range.isNotEmpty) {
                                    rangeByName[name] = range;
                                  }
                                }
                              }
                              if (rangeByName.isNotEmpty) {
                                final Map<DateTime, String> map = _rangesBySchoolGrade[sg] ?? <DateTime, String>{};
                                final Set<String> usedNames = <String>{};
                                added.forEach((date, names) {
                                  for (final n in names) {
                                    final name = (n.trim().isEmpty) ? '수학' : n.trim();
                                    final r = rangeByName[name];
                                    if (r != null && r.isNotEmpty) {
                                      map[DateTime(date.year, date.month, date.day)] = r;
                                      usedNames.add(name);
                                    }
                                  }
                                });
                                _rangesBySchoolGrade[sg] = map;
                                if (usedNames.isNotEmpty) {
                                  _rangeBadgesBySchoolGrade[sg] = pending.where((e) {
                                    final idx = e.indexOf(':');
                                    final name = idx > 0 ? e.substring(0, idx).trim() : e.trim();
                                    return !usedNames.contains(name);
                                  }).toList();
                                  // ignore: avoid_print
                                  print('[RANGE_MATCH] after match: used=$usedNames, remain=${_rangeBadgesBySchoolGrade[sg]}');
                                }
                              }
                            }
                          }
                          // 저장 후 학교 리스트로 복귀
                          _step = 0;
                        });
                        // 날짜 집합을 DB에 저장(선택한 날짜 유지)
                        final sg = _selectedSchoolGrade;
                        if (sg != null) {
                          final idx = sg.lastIndexOf(' ');
                          final schoolName = idx > 0 ? sg.substring(0, idx) : sg;
                          final gradeText = idx > 0 ? sg.substring(idx + 1) : '';
                          final gradeNum = int.tryParse(gradeText.replaceAll('학년', '')) ?? 0;
                          final level = widget.level ?? EducationLevel.middle;
                          await DataManager.instance.saveExamDays(schoolName, level, gradeNum, list.toSet());
                        }
                      }
                    },
                    style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
                    child: const Text('등록'),
                  ),
                ],
              ],
            ),
          ];
        }

        return Column(
          key: const ValueKey('step1'),
          mainAxisSize: MainAxisSize.max,
          children: buildCalendar(_displayMonth),
        );
      });
    }
    // step 2: 날짜 카드만 먼저 보여주고, 카드 탭 시 시험명/범위 입력, 상단에 '일정','범위' 추가 버튼 제공
    final dates = _selectedDays.toList()..sort();
    return Column(
      key: const ValueKey('step2'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Text(_selectedSchoolGrade ?? '', style: const TextStyle(color: Colors.white70)),
          const Spacer(),
          TextButton.icon(onPressed: () async {
            // 일정 추가: 기존 날짜에 시간/장소 등 상세 입력을 붙이는 자리(임시로 시험명 입력 다이얼로그 재사용)
            if (dates.isEmpty) return;
            final key = dates.first; // 예시: 첫 날짜에 추가
            final text = await showDialog<String>(
              context: context,
              builder: (ctx) {
                final ctrl = TextEditingController();
                return AlertDialog(
                  backgroundColor: const Color(0xFF1F1F1F),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  title: const Text('일정 추가', style: TextStyle(color: Colors.white)),
                  content: SizedBox(width: 420, child: TextField(controller: ctrl, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(hintText: '예: 시험 시작 15:00', hintStyle: TextStyle(color: Colors.white38), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)), focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2)))))),
                  actions: [
                    TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('취소', style: TextStyle(color: Colors.white70))),
                    FilledButton(onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()), style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)), child: const Text('추가')),
                  ],
                );
              },
            );
            if (text != null && text.isNotEmpty) {
              final titles = _titlesByDate[key] ?? [];
              setState(() { _titlesByDate[key] = [...titles, text]; });
            }
          }, icon: const Icon(Icons.event, size: 16), label: const Text('일정')),
          const SizedBox(width: 6),
          TextButton.icon(onPressed: () async {
            if (dates.isEmpty) return;
            final key = dates.first;
            final text = await showDialog<String>(
              context: context,
              builder: (ctx) {
                final ctrl = TextEditingController();
                return AlertDialog(
                  backgroundColor: const Color(0xFF1F1F1F),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  title: const Text('범위 추가', style: TextStyle(color: Colors.white)),
                  content: SizedBox(width: 420, child: TextField(controller: ctrl, minLines: 2, maxLines: 4, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(hintText: '예: 수학 I 1~3단원', hintStyle: TextStyle(color: Colors.white38), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)), focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2)))))),
                  actions: [
                    TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('취소', style: TextStyle(color: Colors.white70))),
                    FilledButton(onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()), style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)), child: const Text('추가')),
                  ],
                );
              },
            );
            if (text != null && text.isNotEmpty) {
              final titles = _titlesByDate[key] ?? [];
              setState(() { _titlesByDate[key] = [...titles, '범위|$text']; });
            }
          }, icon: const Icon(Icons.notes, size: 16), label: const Text('범위')),
          const SizedBox(width: 12),
          TextButton.icon(onPressed: () => setState(() => _step = 1), icon: const Icon(Icons.arrow_back, size: 16), label: const Text('뒤로')),
        ]),
        const Text('선택한 날짜', style: TextStyle(color: Colors.white70)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: dates.map((d) {
            final key = DateTime(d.year, d.month, d.day);
            final titles = _titlesByDate[key] ?? [];
            return GestureDetector(
              onTap: () async {
                // 시험명 입력 다이얼로그
                final text = await showDialog<String>(
                  context: context,
                  builder: (ctx) {
                    final ctrl = TextEditingController();
                    final rangeCtrl = TextEditingController();
                    return AlertDialog(
                      backgroundColor: const Color(0xFF1F1F1F),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      title: Text('${key.year}.${key.month}.${key.day} 시험 정보', style: const TextStyle(color: Colors.white)),
                      content: SizedBox(
                        width: 460,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextField(controller: ctrl, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: '시험명', labelStyle: TextStyle(color: Colors.white70), hintText: '예: 중간고사 수학', hintStyle: TextStyle(color: Colors.white38), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)), focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))))),
                            const SizedBox(height: 8),
                            TextField(controller: rangeCtrl, minLines: 2, maxLines: 4, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: '시험 범위', labelStyle: TextStyle(color: Colors.white70), hintText: '예: 수학 I 1~3단원', hintStyle: TextStyle(color: Colors.white38), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)), focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))))),
                          ],
                        ),
                      ),
                      actions: [
                        TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('취소', style: TextStyle(color: Colors.white70))),
                        FilledButton(onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim().isEmpty ? null : '${ctrl.text.trim()}|${rangeCtrl.text.trim()}'), style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)), child: const Text('추가')),
                      ],
                    );
                  },
                );
                if (text != null && text.isNotEmpty) {
                  setState(() { _titlesByDate[key] = [...titles, text]; });
                }
              },
              child: Container(
                width: 160,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2A2A),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white24),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${key.year}.${key.month}.${key.day}', style: const TextStyle(color: Colors.white)),
                  // 날짜 카드 하단의 시험명 표기는 제거 (중복 노출 방지)
                ]),
              ),
            );
          }).toList(),
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
                    final dlgCtx = rootNavigatorKey.currentContext ?? context;
                    await showDialog(
                      context: dlgCtx,
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
                            TextButton(onPressed: () => Navigator.of(dlgCtx).pop(), child: const Text('닫기', style: TextStyle(color: Colors.white70))),
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

 
 