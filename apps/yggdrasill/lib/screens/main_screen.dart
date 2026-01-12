import 'package:flutter/material.dart';
import '../widgets/navigation_rail.dart';
import '../services/data_manager.dart';
import '../models/attendance_record.dart';
import 'student/student_screen.dart';
import 'timetable/timetable_screen.dart';
import 'settings/settings_screen.dart';
import 'resources/resources_screen.dart';
import 'learning/learning_screen.dart';
import 'class_content_screen.dart';
import '../services/tag_store.dart';
import 'dart:async';
import 'learning/tag_preset_dialog.dart';
import '../services/tag_preset_service.dart';
import '../models/student.dart';
import '../models/group_info.dart';
import '../models/student_view_type.dart';
import '../widgets/main_fab_alternative.dart';
import '../models/class_info.dart';
import '../models/session_override.dart';
import '../models/student_time_block.dart';
import 'dart:collection';
import 'dart:math' as math;
import '../models/education_level.dart';
import 'package:collection/collection.dart';
import '../services/homework_store.dart';
import '../services/consult_trial_lesson_service.dart';
import 'learning/homework_quick_add_proxy_dialog.dart';
import 'learning/homework_edit_dialog.dart';
import 'class_content_events_dialog.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';
import 'timetable/views/makeup_view.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with TickerProviderStateMixin {
  // 디버그 로그 스위치 (사이드 시트 출석 분류)
  // ✅ 기본 OFF: 사이드 시트/출석 쪽 대량 로그는 UI 스레드를 막아 렉을 유발할 수 있음(특히 Windows).
  // 필요 시 실행 옵션으로만 활성화:
  // flutter run ... --dart-define=YG_SIDE_SHEET_DEBUG=true
  static const bool _sideSheetDebug =
      bool.fromEnvironment('YG_SIDE_SHEET_DEBUG', defaultValue: false);
  int _selectedIndex = 0; // 0~5 (5는 설정)
  bool _isSideSheetOpen = false;
  late AnimationController _rotationAnimation;
  late Animation<double> _sideSheetAnimation;
  bool _isFabExpanded = false;
  late AnimationController _fabController;
  late Animation<double> _fabScaleAnimation;
  late Animation<double> _fabOpacityAnimation;
  // UI 전용: 칩 상태/애니메이션(제출 회전·확인 깜빡임)
  late AnimationController _uiAnimController;
  // 진단용: 사이드 시트 완료 상태 전이 추적
  bool _sideSheetWasComplete = false;
  // 사이드 시트 데이터 캐시
  bool _sideSheetDataDirty = true;
  List<_AttendanceTarget> _cachedWaiting = const [];
  List<_AttendanceTarget> _cachedAttended = const [];
  List<_AttendanceTarget> _cachedLeaved = const [];
  Map<String, DateTime?> _arrivalBySetCache = const {};
  Map<String, DateTime?> _departureBySetCache = const {};
  Map<DateTime, List<_AttendanceTarget>> _waitingByTimeCache = SplayTreeMap();
  late final ScrollController _attendedScrollCtrl;
  late final ScrollController _waitingScrollCtrl;
  DateTime? _lastPlannedEnsureDay; // 날짜가 바뀔 때만 오늘 planned를 보강 생성
  
  // StudentScreen 관련 상태
  final GlobalKey<StudentScreenState> _studentScreenKey = GlobalKey<StudentScreenState>();
  StudentViewType _viewType = StudentViewType.all;
  final List<GroupInfo> _groups = [];
  final List<Student> _students = [];
  final TextEditingController _searchController = ImeAwareTextEditingController();
  String _searchQuery = '';
  final Set<GroupInfo> _expandedGroups = {};
  double _fabBottomPadding = 16.0;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _snackBarController;
  int? _prevIndex;
  // UI 전용: 과제 칩 상태(학생ID->아이템ID->상태) & 활성 항목
  final Map<String, Map<String, _UiPhase>> _uiPhases = {};
  String? _activeStudentId;
  String? _activeItemId;
  // 진단 로그: 애니메이션/칩 측정
  int _animDebugCounter = 0;
  Timer? _animLogTimer;
  final Set<String> _chipDebugLogged = <String>{};

  // 출석/하원 상태 관리
  final Set<String> _attendedSetIds = {}; // 출석한 setId
  final Set<String> _leavedSetIds = {};   // 하원한 setId

  // 오늘 등원해야 하는 학생(setId별) 리스트 추출
  List<_AttendanceTarget> getTodayAttendanceTargets([
    List<AttendanceRecord>? records,
    Map<String, AttendanceRecord>? outRecordBySet,
  ]) {
    final source = records ?? DataManager.instance.attendanceRecords;
    if (_sideSheetDebug) {
      final todayCount = source.where((r) {
        final now = DateTime.now();
        final a = DateTime(now.year, now.month, now.day);
        final dt = r.classDateTime;
        return dt.year == a.year && dt.month == a.month && dt.day == a.day;
      });
      final presentCnt = todayCount.where((r) => r.isPresent).length;
      final arrivedCnt = todayCount.where((r) => r.arrivalTime != null).length;
      final plannedCnt = todayCount.where((r) => r.isPlanned).length;
      debugPrint('[SIDE][records] today=${todayCount.length} present=$presentCnt arrival=$arrivedCnt planned=$plannedCnt');
      final samplePresent = todayCount.where((r) => r.isPresent || r.arrivalTime != null).take(5);
      for (final r in samplePresent) {
        debugPrint('[SIDE][records][sample-present] student=${r.studentId} setId=${r.setId} dt=${r.classDateTime} arr=${r.arrivalTime} dep=${r.departureTime} isPlanned=${r.isPlanned} id=${r.id}');
      }
    }
    final now = DateTime.now();
    final anchor = DateTime(now.year, now.month, now.day);
    // setId별로 "가장 이른 수업 시간" 하나만 대표로 사용 (실제 등원 기록이 있으면 우선 선택)
    final Map<String, AttendanceRecord> earliestBySet = {};
    int todayTotal = 0;
    int directSetId = 0;
    int resolvedSetId = 0;
    int failedSetId = 0;
    for (final r in source) {
      final dt = r.classDateTime;
      if (dt.year != anchor.year || dt.month != anchor.month || dt.day != anchor.day) continue;
      todayTotal++;
      String effectiveSetId = '';
      if (r.setId != null && r.setId!.isNotEmpty) {
        effectiveSetId = r.setId!;
        directSetId++;
      } else {
        final resolved = _resolveSetIdFromTime(r.studentId, dt);
        if (resolved != null && resolved.isNotEmpty) {
          effectiveSetId = resolved;
          resolvedSetId++;
        } else {
          failedSetId++;
          effectiveSetId = '';
        }
      }
      if (effectiveSetId.isEmpty) {
        if (_sideSheetDebug) {
          debugPrint('[SIDE][skip] setId null student=${r.studentId} dt=$dt recId=${r.id}');
        }
        continue;
      }
      final prev = earliestBySet[effectiveSetId];
      bool preferCurrent = false;
      if (prev == null) {
        preferCurrent = true;
      } else {
        final prevHasAttendance = (prev.arrivalTime != null) || prev.isPresent;
        final curHasAttendance = (r.arrivalTime != null) || r.isPresent;
        final prevPlanned = prev.isPlanned;
        final curPlanned = r.isPlanned;
        if (!prevHasAttendance && curHasAttendance) {
          preferCurrent = true;
        } else if (prevHasAttendance == curHasAttendance) {
          if (prevPlanned && !curPlanned) {
            preferCurrent = true;
          } else if (prevPlanned == curPlanned && dt.isBefore(prev.classDateTime)) {
            preferCurrent = true;
          }
        } else if (prevHasAttendance == curHasAttendance && dt.isBefore(prev.classDateTime)) {
          preferCurrent = true;
        }
      }
      if (preferCurrent) earliestBySet[effectiveSetId] = r;
    }
    if (_sideSheetDebug) {
      debugPrint('[SIDE][map] earliestBySet=${earliestBySet.length}');
      debugPrint(
        '[SIDE][setid] today=$todayTotal direct=$directSetId resolved=$resolvedSetId fail=$failedSetId',
      );
    }
    if (outRecordBySet != null) {
      outRecordBySet.clear();
      outRecordBySet.addAll(earliestBySet);
    }

    final List<_AttendanceTarget> targets = [];
    for (final entry in earliestBySet.entries) {
      final r = entry.value;
      final dt = r.classDateTime;
      final studentInfo = DataManager.instance.students.firstWhereOrNull((s) => s.student.id == r.studentId);
      if (studentInfo == null) continue;
      ClassInfo? classInfo;
      if (r.sessionTypeId != null) {
        classInfo = DataManager.instance.classes.firstWhereOrNull((c) => c.id == r.sessionTypeId);
      }
      final duration = r.classEndTime.difference(r.classDateTime);
      targets.add(_AttendanceTarget(
        setId: entry.key,
        student: studentInfo.student,
        classInfo: classInfo,
        classDateTime: dt,
        duration: duration,
        overrideType: null,
      ));
    }
    targets.sort((a, b) => a.startTime.compareTo(b.startTime));
    return targets;
  }

  String? _resolveSetIdFromTime(String studentId, DateTime classDateTime) {
    final blocks = DataManager.instance.studentTimeBlocks;
    final dayIdx = classDateTime.weekday - 1;
    final targetDate = DateTime(classDateTime.year, classDateTime.month, classDateTime.day);

    bool isActiveOnDate(StudentTimeBlock b) {
      final sd = DateTime(b.startDate.year, b.startDate.month, b.startDate.day);
      final ed = b.endDate == null
          ? null
          : DateTime(b.endDate!.year, b.endDate!.month, b.endDate!.day);
      return !sd.isAfter(targetDate) && (ed == null || !ed.isBefore(targetDate));
    }

    final candidates = blocks
        .where((b) =>
            b.studentId == studentId &&
            b.dayIndex == dayIdx &&
            b.startHour == classDateTime.hour &&
            b.startMinute == classDateTime.minute &&
            isActiveOnDate(b) &&
            b.setId != null &&
            b.setId!.isNotEmpty)
        .toList();
    if (candidates.isEmpty) return null;

    // 같은 시간대에 여러 세그먼트가 있더라도, 가장 최근 시작(start_date가 가장 큰) 블록을 우선한다.
    candidates.sort((a, b) => a.startDate.compareTo(b.startDate));
    return candidates.last.setId;
  }

  void _markSideSheetDirty() {
    final wasDirty = _sideSheetDataDirty;
    _sideSheetDataDirty = true;
    if (_sideSheetDebug && !wasDirty) {
      final now = DateTime.now();
      final len = DataManager.instance.attendanceRecords.length;
      String anim = 'n/a';
      try {
        anim = _rotationAnimation.status.toString();
      } catch (_) {}
      debugPrint('[SIDE][dirty] t=${now.toIso8601String()} len=$len anim=$anim');
    }
  }

  void _recomputeSideSheetCache(List<AttendanceRecord> records) {
    final Map<String, AttendanceRecord> recordBySet = {};
    final attendanceTargets = getTodayAttendanceTargets(records, recordBySet);

    final List<_AttendanceTarget> leaved = [];
    final List<_AttendanceTarget> attended = [];
    final List<_AttendanceTarget> waiting = [];
    final Map<String, DateTime?> arrivalBySet = {};
    final Map<String, DateTime?> departureBySet = {};

    for (final t in attendanceTargets) {
      final AttendanceRecord? rec = recordBySet[t.setId];
      DateTime? arr = rec?.arrivalTime;
      DateTime? dep = rec?.departureTime;
      bool isArrived = arr != null || (rec?.isPresent ?? false);
      bool isLeaved = dep != null;
      if (!isArrived && _attendedSetIds.contains(t.setId)) {
        isArrived = true;
        arr = _attendTimes[t.setId];
      }
      if (!isLeaved && _leavedSetIds.contains(t.setId)) {
        isLeaved = true;
        dep = _leaveTimes[t.setId];
      }
      arrivalBySet[t.setId] = arr;
      departureBySet[t.setId] = dep;
      if (isLeaved) {
        leaved.add(t);
      } else if (isArrived) {
        attended.add(t);
      } else {
        waiting.add(t);
      }
    }

    attended.sort((a, b) {
      final ta = arrivalBySet[a.setId];
      final tb = arrivalBySet[b.setId];
      if (ta == null && tb == null) return 0;
      if (ta == null) return 1;
      if (tb == null) return -1;
      return ta.compareTo(tb);
    });

    final Map<DateTime, List<_AttendanceTarget>> waitingByTime = SplayTreeMap();
    for (final t in waiting) {
      waitingByTime.putIfAbsent(t.startTime, () => []).add(t);
    }

    _cachedWaiting = waiting;
    _cachedAttended = attended;
    _cachedLeaved = leaved;
    _arrivalBySetCache = arrivalBySet;
    _departureBySetCache = departureBySet;
    _waitingByTimeCache = waitingByTime;
    _sideSheetDataDirty = false;
  }

  // 출석/하원 시간 기록용
  final Map<String, DateTime> _attendTimes = {};
  final Map<String, DateTime> _leaveTimes = {};

  // 수업 태그(메모) - 세션(setId)별 적용 태그 이벤트 (메모리 전용)
  // V2로 이름 변경하여 핫리로드 시 이전 타입과 충돌 방지
  final Map<String, List<_ClassTagEvent>> _classTagEventsBySetId = {};
  // 선택 가능한 태그 목록 (기본 + 사용자가 추가)
  final List<_ClassTag> _availableClassTags = [
    const _ClassTag(name: '졸음', color: Color(0xFF7E57C2), icon: Icons.bedtime),
    const _ClassTag(name: '스마트폰', color: Color(0xFFF57C00), icon: Icons.phone_iphone),
    const _ClassTag(name: '떠듬', color: Color(0xFFEF5350), icon: Icons.record_voice_over),
    const _ClassTag(name: '딴짓', color: Color(0xFF90A4AE), icon: Icons.gesture),
    const _ClassTag(name: '기록', color: Color(0xFF1976D2), icon: Icons.edit_note),
  ];

  // OverlayEntry 툴팁 상태
  OverlayEntry? _tooltipOverlay;
  void _showTooltip(Offset position, String text) {
    // print('[DEBUG] _showTooltip called: position= [38;5;246m$position [0m, text=$text');
    _removeTooltip();
    final overlay = Overlay.of(context);
    _tooltipOverlay = OverlayEntry(
      builder: (context) => Positioned(
        left: position.dx + 12, // 마우스 오른쪽 약간 띄움
        top: position.dy + 12,  // 마우스 아래 약간 띄움
        child: Material(
          color: Colors.transparent,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 160),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: const Color(0xFF232326),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white24, width: 1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.18),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Text(
              text,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ),
      ),
    );
    overlay.insert(_tooltipOverlay!);
    // print('[DEBUG] _showTooltip OverlayEntry inserted');
  }
  void _removeTooltip() {
    // print('[DEBUG] _removeTooltip called');
    _tooltipOverlay?.remove();
    _tooltipOverlay = null;
  }

  // 카드 레이아웃 상수 (클래스 필드로 이동)
  static const double _cardHeight = 42.0;
  static const double _cardMargin = 4.0;
  static const double _cardSpacing = 8.0;
  static const double _attendedRunSpacing = 16.0;
  static const int _attendedMaxLines = 15;
  static double get _cardActualHeight => _cardHeight;

  static String _educationLevelToKorean(EducationLevel level) {
    switch (level) {
      case EducationLevel.elementary:
        return '초등';
      case EducationLevel.middle:
        return '중등';
      case EducationLevel.high:
        return '고등';
    }
    return '';
  }

  @override
  void initState() {
    super.initState();
    // 과제 데이터 DB에서 1회 로드
    HomeworkStore.instance.loadAll();
    // 출석 데이터 변경 시 사이드 시트 캐시 무효화
    DataManager.instance.attendanceRecordsNotifier.addListener(_markSideSheetDirty);
    _rotationAnimation = AnimationController(
      duration: const Duration(milliseconds: 240),
      vsync: this,
    );
    // 진단 로그 제거됨
    _sideSheetAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _rotationAnimation,
        curve: Curves.easeInOutCubic,
      ),
    );
    _fabController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _fabScaleAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _fabController,
        curve: Curves.easeOut,
      ),
    );
    _fabOpacityAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _fabController,
        curve: Curves.easeInOut,
      ),
    );
    // UI 전용 애니메이션 틱(회전·깜빡임 공통)
    _uiAnimController = AnimationController(
      duration: const Duration(milliseconds: 1800),
      vsync: this,
    )..repeat();
    // 진단 타이머 제거됨
    // 스크롤 컨트롤러 초기화
    _attendedScrollCtrl = ScrollController();
    _waitingScrollCtrl = ScrollController();
    _initializeData();
  }

  Future<void> _initializeData() async {
    await DataManager.instance.initialize();
    
    // 강제 마이그레이션 실행
    await DataManager.instance.forceMigration();
    
    // 어제(KST) 미하원 자동 처리: 등원만 있고 하원이 없는 경우 등원+수업시간 후 하원으로 기록
    await DataManager.instance.fixMissingDeparturesForYesterdayKst();
    
    // 태그 이벤트 DB → 메모리 적재
    await TagStore.instance.loadAllFromDb();
    
    // 오늘의 출석 기록을 바탕으로 등원/하원 상태 복원
    _restoreTodayAttendanceStatus();
    
    setState(() {
      _groups.clear();
      _groups.addAll(DataManager.instance.groups);
      _students.clear();
      _students.addAll(DataManager.instance.students.map((s) => s.student));
    });
  }

  // 오늘의 출석 기록을 바탕으로 등원/하원 상태 복원
  void _restoreTodayAttendanceStatus() {
    final today = DateTime.now();
    final todayStart = DateTime(today.year, today.month, today.day);
    final todayEnd = todayStart.add(const Duration(days: 1));
    
    final todayAttendanceRecords = DataManager.instance.attendanceRecords
        .where((record) {
            final recordDate = DateTime(record.classDateTime.year, record.classDateTime.month, record.classDateTime.day);
            return recordDate.isAfter(todayStart.subtract(const Duration(days: 1))) && 
                   recordDate.isBefore(todayEnd) &&
                   record.isPresent;
        })
        .toList();
    
    // 오늘의 등원/하원 상태 복원
    for (final record in todayAttendanceRecords) {
      // ✅ 중요:
      // 같은 학생이 "하루에 2개 수업(서로 다른 set_id)"인 경우가 있으므로,
      // 출석 기록 1건을 보고 그 학생의 "오늘 요일 전체 setId"를 출석 처리하면 안 된다.
      // -> record에 대응하는 setId 1개만 복원한다.
      String? setId = record.setId?.trim();
      if (setId == null || setId.isEmpty) {
        setId = _resolveSetIdFromTime(record.studentId, record.classDateTime);
      }
      if (setId != null && setId.isNotEmpty) {
        // 등원 시간이 있으면 등원 상태로 설정
        if (record.arrivalTime != null) {
          _attendedSetIds.add(setId);
          _attendTimes[setId] = record.arrivalTime!;
        }
        // 하원 시간이 있으면 하원 상태로 설정
        if (record.departureTime != null) {
          _leavedSetIds.add(setId);
          _leaveTimes[setId] = record.departureTime!;
        }
      }

      // 보강/추가수업(오버라이드) 매핑: replacement 시간과 출석 기록(classDateTime)이 같으면 ov.id를 setId로 간주하여 복원
      bool sameMinute(DateTime a, DateTime b) =>
          a.year == b.year && a.month == b.month && a.day == b.day && a.hour == b.hour && a.minute == b.minute;
      for (final ov in DataManager.instance.sessionOverrides) {
        if (ov.studentId != record.studentId) continue;
        if (ov.reason != OverrideReason.makeup) continue; // 보강만 대상
        if (!(ov.overrideType == OverrideType.add || ov.overrideType == OverrideType.replace)) continue;
        if (ov.status == OverrideStatus.canceled) continue; // 취소 제외 (planned/completed 모두 복원)
        final rep = ov.replacementClassDateTime;
        if (rep == null) continue;
        if (!sameMinute(rep, record.classDateTime)) continue;
        final String key = ov.id;
        if (record.arrivalTime != null) {
          _attendedSetIds.add(key);
          _attendTimes[key] = record.arrivalTime!;
        }
        if (record.departureTime != null) {
          _leavedSetIds.add(key);
          _leaveTimes[key] = record.departureTime!;
        }
      }
    }
  }

  @override
  void dispose() {
    DataManager.instance.attendanceRecordsNotifier.removeListener(_markSideSheetDirty);
    _rotationAnimation.dispose();
    _fabController.dispose();
    _searchController.dispose();
    _attendedScrollCtrl.dispose();
    _waitingScrollCtrl.dispose();
    _uiAnimController.dispose();
    _animLogTimer?.cancel();
    super.dispose();
  }

  void _toggleSideSheet() {
    if (_rotationAnimation.status == AnimationStatus.completed) {
      if (_sideSheetDebug) {
        debugPrint('[SIDE][toggle] close');
      }
      _rotationAnimation.reverse();
    } else {
      _sideSheetDataDirty = true;
      // ✅ planned가 없으면 사이드 시트가 비어보일 수 있으므로,
      // 날짜가 바뀌어 처음 열 때 한 번만 planned 보강 생성(누락분만 추가됨).
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      if (_lastPlannedEnsureDay == null ||
          _lastPlannedEnsureDay!.year != today.year ||
          _lastPlannedEnsureDay!.month != today.month ||
          _lastPlannedEnsureDay!.day != today.day) {
        _lastPlannedEnsureDay = today;
        if (_sideSheetDebug) {
          debugPrint(
            '[SIDE][toggle] open -> ensurePlanned(days=2) recordsLen=${DataManager.instance.attendanceRecords.length}',
          );
        }
        unawaited(DataManager.instance.ensurePlannedAttendanceForNextDays(days: 2));
      } else {
        if (_sideSheetDebug) {
          debugPrint('[SIDE][toggle] open (ensure skipped - already ran today)');
        }
      }
      // 시범 수업(문의 노트) 슬롯도 사이드 시트에서 사용할 수 있도록 lazy-load
      unawaited(ConsultTrialLessonService.instance.load());
      _rotationAnimation.forward();
    }
  }

  Future<void> _showLeavedStudentsDialog(
    List<_AttendanceTarget> leaved,
    Map<String, DateTime?> arrivalBySet,
    Map<String, DateTime?> departureBySet,
  ) async {
    final entries = leaved
        .map((target) => _LeavedDialogEntry(
              target: target,
              arrival: arrivalBySet[target.setId],
              departure: departureBySet[target.setId],
            ))
        .toList()
      ..sort((a, b) {
        final DateTime aKey = a.departure ?? a.arrival ?? DateTime.fromMillisecondsSinceEpoch(0);
        final DateTime bKey = b.departure ?? b.arrival ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bKey.compareTo(aKey);
      });

    final double listHeight = entries.isEmpty
        ? 140.0
        : math.min(420.0, math.max(220.0, entries.length * 76.0));

    await showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.55),
      builder: (dialogContext) {
        Widget buildHeader() {
          return SizedBox(
            height: 48,
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  margin: const EdgeInsets.only(right: 12),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: IconButton(
                    tooltip: '닫기',
                    icon: const Icon(Icons.arrow_back, color: Colors.white70, size: 20),
                    padding: EdgeInsets.zero,
                    onPressed: () => Navigator.of(dialogContext).pop(),
                  ),
                ),
                const Text(
                  '하원 리스트',
                  style: TextStyle(
                    color: Color(0xFFEAF2F2),
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          );
        }

        Widget buildTimeBadge(String label, String value) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF1B6B63).withOpacity(0.18),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '$label $value',
              style: const TextStyle(
                color: Color(0xFFEAF2F2),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          );
        }

        return Dialog(
          backgroundColor: const Color(0xFF0B1112),
          insetPadding: const EdgeInsets.all(24),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(26, 26, 26, 22),
              decoration: BoxDecoration(
                color: const Color(0xFF0B1112),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  buildHeader(),
                  const SizedBox(height: 14),
                  SizedBox(
                    height: listHeight,
                    child: entries.isEmpty
                        ? const Center(
                            child: Text(
                              '하원한 학생이 아직 없어요.',
                              style: TextStyle(
                                color: Color(0xFF9FB3B3),
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          )
                        : Scrollbar(
                            thumbVisibility: true,
                            child: ListView.separated(
                              itemCount: entries.length,
                              separatorBuilder: (_, __) => const SizedBox(height: 12),
                              itemBuilder: (context, index) {
                                final entry = entries[index];
                                final arrivalText = entry.arrival != null ? _formatTime(entry.arrival!) : '--:--';
                                final departureText = entry.departure != null ? _formatTime(entry.departure!) : '--:--';
                                return Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF10171A),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(color: const Color(0xFF1B6B63).withOpacity(0.25)),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        entry.target.student.name,
                                        style: const TextStyle(
                                          color: Color(0xFFEAF2F2),
                                          fontSize: 17,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      if (entry.target.classInfo != null) ...[
                                        const SizedBox(height: 4),
                                        Text(
                                          entry.target.classInfo!.name,
                                          style: const TextStyle(
                                            color: Color(0xFF7F8A8E),
                                            fontSize: 13,
                                          ),
                                        ),
                                      ],
                                      const SizedBox(height: 10),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: [
                                          buildTimeBadge('등원', arrivalText),
                                          buildTimeBadge('하원', departureText),
                                        ],
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showMakeupManagementDialog() async {
    await showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) {
        return Dialog(
          backgroundColor: const Color(0xFF1F1F1F),
          insetPadding: const EdgeInsets.fromLTRB(42, 42, 42, 32),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: const SizedBox(
            width: 770,
            height: 760,
            child: MakeupView(),
          ),
        );
      },
    );
  }

  Widget _buildContent() {
    
    switch (_selectedIndex) {
      case 0:
        return const ClassContentScreen();
      case 1:
        return StudentScreen(key: _studentScreenKey);
      case 2:
        return TimetableScreen();
      case 3:
        return const LearningScreen();
      case 4:
        return const ResourcesScreen();
      case 5:
        return const SettingsScreen();
      default:
        return const SizedBox();
    }
  }

  void _showClassRegistrationDialog() {
    // ✅ 학생 탭 "추가" 정책 변경:
    // 드롭다운(학생/그룹) 제거 → 추가 버튼은 항상 학생 등록으로 진입
    _showStudentRegistrationDialog();
  }

  void _showStudentRegistrationDialog() {
    if (_studentScreenKey.currentState != null) {
      _studentScreenKey.currentState!.showStudentRegistrationDialog();
    }
  }

  @override
  Widget build(BuildContext context) {
    // print('[DEBUG] MainScreen build');
    // 안전 가드: 네비게이션 레일은 0~4까지만 허용하므로 표시 인덱스를 보정
    final int _railSelectedIndex = (_selectedIndex >= 0 && _selectedIndex <= 5) ? _selectedIndex : 0;
    return Scaffold(
      body: Row(
        children: [
          CustomNavigationRail(
            selectedIndex: _railSelectedIndex,
            onDestinationSelected: (int index) {
              setState(() {
                _selectedIndex = index;
              });
            },
            rotationAnimation: _rotationAnimation,
            onMenuPressed: _toggleSideSheet,
          ),
          Container(
            width: 1,
            height: double.infinity,
            color: const Color(0xFF223131),
          ),
          AnimatedBuilder(
            animation: _sideSheetAnimation,
            builder: (context, child) {
              final progress = _sideSheetAnimation.value;
              
              final bool isComplete = _rotationAnimation.status == AnimationStatus.completed && progress >= 1.0;
              if (isComplete != _sideSheetWasComplete) { _sideSheetWasComplete = isComplete; }
              // 카드 리스트를 한 줄로 묶어서 ... 처리할 수 있도록 helper
              Widget _ellipsisWrap(List<Widget> cards, {int maxLines = 2, double spacing = 8, double runSpacing = 8}) {
                // 한 줄에 최대 3개 카드만 보이게 제한 (예시)
                const int maxPerLine = 3;
                List<Widget> lines = [];
                int i = 0;
                while (i < cards.length && lines.length < maxLines) {
                  int end = (i + maxPerLine < cards.length) ? i + maxPerLine : cards.length;
                  lines.add(Row(
                    mainAxisSize: MainAxisSize.min,
                    children: cards.sublist(i, end),
                  ));
                  i = end;
                }
                if (i < cards.length) {
                  lines.add(const Text('...', style: TextStyle(color: Colors.white54, fontSize: 18)));
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: lines,
                );
              }
              final screenWidth = MediaQuery.of(context).size.width;
              // 최대창 기준 450px이던 시트 폭을 화면 너비 비율(대략 26%)로 환산
              final baseRatio = 0.21; // 450 / 1728 ≈ 0.26
              final maxWidth = screenWidth * baseRatio;
              // progress로 내부 콘텐츠는 제어하되, Container 자체는 닫힌 상태에서 0px로 만들어 여백이 생기지 않게 처리
              final containerWidth = progress == 0 ? 0.0 : (maxWidth * progress).clamp(0.0, maxWidth);
              
              // 파생 리스트 로그는 ValueListenableBuilder 내부에서 출력합니다.

              // 애니메이션 진행 중에는 내용 위젯을 전혀 생성하지 않고, 빈 컨테이너만 렌더링
              if (isComplete != _sideSheetWasComplete) {
                if (_sideSheetDebug) {
                  debugPrint(
                    '[SIDE][sheet] complete=$isComplete progress=${progress.toStringAsFixed(3)} status=${_rotationAnimation.status} width=${containerWidth.toStringAsFixed(1)}',
                  );
                }
                _sideSheetWasComplete = isComplete;
              }
              if (!isComplete) {
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeInOut,
                  width: containerWidth,
                  color: const Color(0xFF0B1112),
                );
              }

              return ValueListenableBuilder<List<AttendanceRecord>>(
                valueListenable: DataManager.instance.attendanceRecordsNotifier,
                builder: (context, _records, _) {
                  if (_sideSheetDataDirty) {
                    if (_sideSheetDebug) {
                      debugPrint('[SIDE][recompute-start] recordsLen=${_records.length}');
                    }
                    _recomputeSideSheetCache(_records);
                    if (_sideSheetDebug) {
                      debugPrint('[SIDE][recompute] waiting=${_cachedWaiting.length}, attended=${_cachedAttended.length}, leaved=${_cachedLeaved.length}');
                    }
                  }
                  final attended = _cachedAttended;
                  final leaved = _cachedLeaved;
                  final arrivalBySet = _arrivalBySetCache;
                  final departureBySet = _departureBySetCache;
                  final waitingByTime = _waitingByTimeCache;

                  return ValueListenableBuilder<List<ConsultTrialLessonSlot>>(
                    valueListenable: ConsultTrialLessonService.instance.slotsNotifier,
                    builder: (context, trialSlots, _) {
                      final now2 = DateTime.now();
                      final todayDate = DateTime(now2.year, now2.month, now2.day);
                      DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

                      final trialToday = trialSlots.where((s) {
                        final wk = _dateOnly(s.weekStart);
                        final slotDate = _dateOnly(wk.add(Duration(days: s.dayIndex)));
                        return slotDate == todayDate;
                      }).toList();

                      final trialAttended = trialToday
                          .where((s) => s.arrivalTime != null && s.departureTime == null)
                          .toList()
                        ..sort((a, b) {
                          final ta = a.hour * 60 + a.minute;
                          final tb = b.hour * 60 + b.minute;
                          final t = ta.compareTo(tb);
                          if (t != 0) return t;
                          return a.title.compareTo(b.title);
                        });
                      final trialWaiting = trialToday
                          .where((s) => s.arrivalTime == null)
                          .toList()
                        ..sort((a, b) {
                          final ta = a.hour * 60 + a.minute;
                          final tb = b.hour * 60 + b.minute;
                          final t = ta.compareTo(tb);
                          if (t != 0) return t;
                          return a.title.compareTo(b.title);
                        });

                      final trialWaitingByTime = SplayTreeMap<DateTime, List<ConsultTrialLessonSlot>>();
                      for (final s in trialWaiting) {
                        final k = DateTime(todayDate.year, todayDate.month, todayDate.day, s.hour, s.minute);
                        (trialWaitingByTime[k] ??= <ConsultTrialLessonSlot>[]).add(s);
                      }

                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        curve: Curves.easeInOut,
                        width: containerWidth,
                        color: const Color(0xFF0B1112),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Column(
                                children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
                                child: SizedBox(
                                  height: 44,
                                  child: Row(
                                    children: [
                                      const _TodayDateLabel(),
                                      const Spacer(),
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Tooltip(
                                            message: '보강 관리',
                                            child: IconButton(
                                              icon: const Icon(Icons.event_repeat, color: Colors.white70, size: 22),
                                              padding: EdgeInsets.zero,
                                              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                                              onPressed: _showMakeupManagementDialog,
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          Tooltip(
                                            message: '수업 타임라인',
                                            child: IconButton(
                                              icon: const Icon(Icons.timeline, color: Colors.white70, size: 22),
                                              padding: EdgeInsets.zero,
                                              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                                              onPressed: () async {
                                                await showDialog(context: context, builder: (_) => const ClassContentEventsDialog());
                                              },
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Tooltip(
                                            message: '하원 리스트',
                                            child: IconButton(
                                              icon: const Icon(Icons.featured_play_list, color: Colors.white70, size: 22),
                                              padding: EdgeInsets.zero,
                                              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                                              onPressed: () async {
                                                await _showLeavedStudentsDialog(leaved, arrivalBySet, departureBySet);
                                              },
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              // 출석 박스
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 24.0),
                                child: Container(
                                  margin: const EdgeInsets.symmetric(vertical: 16),
                                  width: double.infinity,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF15171C),
                                    border: Border.all(color: const Color(0xFF15171C), width: 2),
                                    borderRadius: BorderRadius.circular(18),
                                  ),
                                  constraints: BoxConstraints(
                                    minHeight: _cardActualHeight * ((containerWidth / 420.0).clamp(0.78, 1.0)),
                                    maxHeight: _cardActualHeight * ((containerWidth / 420.0).clamp(0.78, 1.0)) * _attendedMaxLines + _attendedRunSpacing * ((containerWidth / 420.0).clamp(0.78, 1.0)) * (_attendedMaxLines - 1),
                                  ),
                                  padding: const EdgeInsets.symmetric(vertical: 24.0, horizontal: 16.0),
                                  child: Scrollbar(
                                    controller: _attendedScrollCtrl,
                                    thumbVisibility: true,
                                    child: SingleChildScrollView(
                                      controller: _attendedScrollCtrl,
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          if (attended.isEmpty && trialAttended.isEmpty)
                                            const Center(
                                              child: Text(
                                                '출석',
                                                style: TextStyle(
                                                  color: Color(0xFF9FB3B3),
                                                  fontSize: 22,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),
                                          if (attended.isNotEmpty)
                                            Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                for (int i = 0; i < attended.length; i++) ...[
                                                  _buildAttendanceCard(
                                                    attended[i],
                                                    status: 'attended',
                                                    key: ValueKey('attended_${attended[i].setId}'),
                                                    scale: ((containerWidth / 420.0).clamp(0.78, 1.0)),
                                                    arrival: arrivalBySet[attended[i].setId],
                                                    departure: departureBySet[attended[i].setId],
                                                  ),
                                                  if (i != attended.length - 1) SizedBox(height: 8 * ((containerWidth / 420.0).clamp(0.78, 1.0))),
                                                ]
                                              ],
                                            ),
                                          if (trialAttended.isNotEmpty) ...[
                                            if (attended.isNotEmpty) const SizedBox(height: 8),
                                            for (int i = 0; i < trialAttended.length; i++) ...[
                                              _buildTrialLessonAttendanceCard(
                                                trialAttended[i],
                                                status: 'attended',
                                                key: ValueKey('trial_attended_${trialAttended[i].id}'),
                                                scale: ((containerWidth / 420.0).clamp(0.78, 1.0)),
                                              ),
                                              if (i != trialAttended.length - 1)
                                                SizedBox(height: 8 * ((containerWidth / 420.0).clamp(0.78, 1.0))),
                                            ],
                                          ],
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              // 출석 전 학생 리스트
                              if (waitingByTime.isNotEmpty || trialWaitingByTime.isNotEmpty)
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.only(top: 0, left: 24.0, right: 24.0, bottom: 24.0),
                                    child: Scrollbar(
                                      controller: _waitingScrollCtrl,
                                      thumbVisibility: true,
                                      child: ListView(
                                        controller: _waitingScrollCtrl,
                                        padding: EdgeInsets.zero,
                                        children: [
                                          for (final t in (<DateTime>{
                                            ...waitingByTime.keys,
                                            ...trialWaitingByTime.keys,
                                          }.toList()
                                            ..sort((a, b) => a.compareTo(b)))) ...[
                                            Padding(
                                              padding: const EdgeInsets.only(bottom: 4.0),
                                              child: Center(
                                                child: Text(
                                                  _formatTime(t),
                                                  style: const TextStyle(color: Colors.white54, fontSize: 14, fontWeight: FontWeight.bold),
                                                ),
                                              ),
                                            ),
                                            Center(
                                              child: Wrap(
                                                alignment: WrapAlignment.center,
                                                spacing: _cardSpacing * ((containerWidth / 420.0).clamp(0.78, 1.0)),
                                                runSpacing: _cardSpacing * ((containerWidth / 420.0).clamp(0.78, 1.0)),
                                                children: [
                                                  for (final w in (waitingByTime[t] ?? const <_AttendanceTarget>[]))
                                                    _buildAttendanceCard(
                                                      w,
                                                      status: 'waiting',
                                                      key: ValueKey('waiting_${w.setId}'),
                                                      scale: ((containerWidth / 420.0).clamp(0.78, 1.0)),
                                                      arrival: arrivalBySet[w.setId],
                                                      departure: departureBySet[w.setId],
                                                    ),
                                                  for (final s in (trialWaitingByTime[t] ?? const <ConsultTrialLessonSlot>[]))
                                                    _buildTrialLessonAttendanceCard(
                                                      s,
                                                      status: 'waiting',
                                                      key: ValueKey('trial_waiting_${s.id}'),
                                                      scale: ((containerWidth / 420.0).clamp(0.78, 1.0)),
                                                    ),
                                                ],
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          // 커버 생략
                          // 하단 임시 A/B 버튼 제거됨
                        ],
                      ),
                    );
                    },
                  );
                },
              );
            },
          ),
          Container(
            width: 1,
            color: const Color(0xFF4A4A4A),
          ),
          Expanded(
            child: _buildContent(),
          ),
        ],
      ),
      floatingActionButton: MainFabAlternative(),
    );
  }

  void _showFloatingSnackBar(BuildContext context, String message) {
    setState(() {
      _fabBottomPadding = 80.0 + 16.0;
    });
    _snackBarController = ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFF2A2A2A),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.only(bottom: 16.0, right: 16.0, left: 16.0),
        duration: const Duration(seconds: 2),
      ),
    );
    _snackBarController?.closed.then((_) {
      if (mounted) {
        setState(() {
          _fabBottomPadding = 16.0;
        });
      }
    });
  }

  // 출석/하원 카드 위젯 (툴팁은 외부에서 처리)
  Widget _buildAttendanceCard(_AttendanceTarget t, {required String status, Key? key, double scale = 1.0, DateTime? arrival, DateTime? departure}) {
    Color borderColor;
    Color textColor = Colors.white70;
    Widget nameWidget;
    // 밑줄 색상 결정 (보강=파란색, 추가수업=초록색)
    final Color? underlineColor = t.overrideType == OverrideType.replace
        ? const Color(0xFF1976D2)
        : (t.overrideType == OverrideType.add ? const Color(0xFF4CAF50) : null);
    final bool isSpecialOverride = t.overrideType == OverrideType.replace || t.overrideType == OverrideType.add;
    switch (status) {
      case 'attended':
        borderColor = const Color(0xFF33A373);
        textColor = const Color(0xFFEAF2F2);
        nameWidget = MouseRegion(
          onEnter: (event) {
            final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
            final offset = overlay.globalToLocal(event.position);
            final DateTime? attendTime = arrival ?? _attendTimes[t.setId];
            final tip = attendTime != null ? '등원: ' + _formatTime(attendTime) : '등원 시간 없음';
            _showTooltip(offset, tip);
          },
          onExit: (_) => _removeTooltip(),
          child: Text(
            t.student.name,
            style: TextStyle(
              color: textColor,
              fontSize: 16,
              fontWeight: FontWeight.w500,
              decoration: underlineColor != null ? TextDecoration.underline : null,
              decorationColor: underlineColor,
              decorationThickness: underlineColor != null ? 2 : null,
            ),
          ),
        );
        break;
      case 'leaved':
        borderColor = t.classInfo?.color ?? Colors.grey.shade700;
        textColor = Colors.white70;
        nameWidget = MouseRegion(
          onEnter: (event) {
            final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
            final offset = overlay.globalToLocal(event.position);
            // 등원/하원 시간 표시
            final DateTime? attendTime = arrival ?? _attendTimes[t.setId];
            final DateTime? leaveTime = departure ?? _leaveTimes[t.setId];
            String tooltip = '';
            if (attendTime != null) {
              tooltip += '등원: ' + _formatTime(attendTime) + '\n';
            }
            if (leaveTime != null) {
              tooltip += '하원: ' + _formatTime(leaveTime);
            }
            if (tooltip.isEmpty) tooltip = '시간 정보 없음';
            _showTooltip(offset, tooltip);
          },
          onExit: (_) => _removeTooltip(),
          child: Text(
            t.student.name,
            style: TextStyle(
              color: textColor,
              fontSize: 16,
              fontWeight: FontWeight.w500,
              decoration: underlineColor != null ? TextDecoration.underline : null,
              decorationColor: underlineColor,
              decorationThickness: underlineColor != null ? 2 : null,
            ),
          ),
        );
        break;
      default:
        // waiting(등원 예정)
        // - 기본: 테두리=회색(통일)
        // - 수업이 있으면: 이름만 수업 색상
        // - 보강/추가수업: 테두리만 해당 색상(보강=파랑, 추가=초록)
        borderColor = isSpecialOverride
            ? (t.overrideType == OverrideType.replace
                ? const Color(0xFF1976D2)
                : const Color(0xFF4CAF50))
            : Colors.grey;
        final Color? classColor = t.classInfo?.color;
        textColor = (!isSpecialOverride && classColor != null) ? classColor : Colors.white70;
        nameWidget = Text(
          t.student.name,
          style: TextStyle(
            color: textColor,
            fontSize: 16,
            fontWeight: FontWeight.w500,
            // waiting에서는 underline을 쓰지 않고(이질감/중복) 테두리/이름색 규칙으로만 표현한다.
          ),
        );
    }
    // 텍스트 자체의 underline을 사용하여 높이 증가 없이 이름 전체에 밑줄 적용
    // 이름 + 과제 요약 칩들
    final List<Widget> chips = [];
    final hwList = HomeworkStore.instance.items(t.student.id);
    for (final hw in hwList.where((e) => e.status != HomeworkStatus.completed).take(3)) {
      chips.add(const SizedBox(width: 8));
      chips.add(
        MouseRegion(
          onEnter: (e) {
            final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
            final offset = overlay.globalToLocal(e.position);
            _showTooltip(offset, hw.body.isEmpty ? '(내용 없음)' : hw.body);
          },
          onExit: (_) => _removeTooltip(),
          child: GestureDetector(
            onTap: () async {
              await _openHomeworkEditDialog(t.student.id, hw.id);
              if (mounted) setState(() {});
            },
            onLongPress: () async {
              // 이어가기: 동일 제목/색상으로 내용만 빈 과제 추가
              HomeworkStore.instance.continueAdd(t.student.id, hw.id, body: '');
              setState(() {});
            },
            onSecondaryTap: () {
              // 완료 처리
              unawaited(HomeworkStore.instance.complete(t.student.id, hw.id));
              setState(() {});
            },
            child: Container(
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: (HomeworkStore.instance.runningOf(t.student.id)?.id == hw.id)
                    ? Colors.transparent
                    : const Color(0xFF2F353A),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: hw.color.withOpacity(0.6), width: 1),
              ),
              alignment: Alignment.center,
              child: Text(
                hw.title,
                style: const TextStyle(
                  color: Color(0xFFEAF2F2),
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      );
    }
    final Widget attendedChild = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        nameWidget,
        const SizedBox(width: 8),
        // 버튼 내부로 이동한 태그 추가 아이콘
        Tooltip(
          message: '태그 추가',
          child: IconButton(
            onPressed: () => _openClassTagDialog(t),
            icon: const Icon(Icons.circle_outlined, color: Color(0xFFEAF2F2)),
            iconSize: 14,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          ),
        ),
        const SizedBox(width: 4),
        // 버튼 내부로 이동한 과제 추가 아이콘
        Tooltip(
          message: '과제 추가',
          child: IconButton(
            onPressed: () async {
              // 빠른 추가: 제목/색상 간단 입력 다이얼로그 호출 대신 학습 화면과 동일 다이얼로그 재사용
              final item = await showDialog<dynamic>(
                context: context,
                builder: (ctx) => HomeworkQuickAddProxyDialog(studentId: t.student.id, initialTitle: '', initialColor: const Color(0xFF1976D2)),
              );
              if (item is Map<String, dynamic>) {
                // 전달된 studentId, title, body, color 사용
                if (item['studentId'] == t.student.id) {
                  // LearningScreen의 스토어를 통해 추가 (전역 스토어 사용)
                  HomeworkStore.instance.add(item['studentId'], title: item['title'], body: item['body'], color: item['color']);
                  // 출석 중에 추가된 과제는 오늘 내로 하원 시 숙제로 전환되도록 firstStartedAt가 설정될 수 있음
                  setState(() {});
                }
              }
            },
            icon: const Icon(Icons.add_rounded, color: Color(0xFFEAF2F2)),
            iconSize: 16,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          ),
        ),
      ],
    );
    final Widget cardChild = nameWidget; // 기본은 이름만 사용 (waiting/leaved)
    if (status == 'attended') {
      // 출석(파란 네모) 카드: 가로 스크롤로 과제칩 표시(줄바꿈 없음)
      return Row(
        key: key,
        mainAxisSize: MainAxisSize.max,
        children: [
          GestureDetector(
            onTap: () async {
              final now = DateTime.now();
              setState(() {
                _leavedSetIds.add(t.setId);
                _leaveTimes[t.setId] = now;
                _sideSheetDataDirty = true;
              });
              try {
                final classDateTime = t.classDateTime;
                final existing = DataManager.instance.getAttendanceRecord(t.student.id, classDateTime);
                final DateTime arrival2 = existing?.arrivalTime ?? _attendTimes[t.setId] ?? now;
                await DataManager.instance.saveOrUpdateAttendance(
                  studentId: t.student.id,
                  classDateTime: classDateTime,
                  classEndTime: classDateTime.add(t.duration),
                  className: t.classInfo?.name ?? '수업',
                  isPresent: true,
                  arrivalTime: arrival2,
                  departureTime: now,
                  setId: t.setId,
                  sessionTypeId: t.classInfo?.id,
                );
                // 하원 시 미완료 과제들을 숙제로 표시
                HomeworkStore.instance.markIncompleteAsHomework(t.student.id);
              } catch (e) {
                print('[ERROR] 출석 기록 동기화 실패: $e');
              }
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: EdgeInsets.zero,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              decoration: BoxDecoration(
              // 등원 완료(출석) 카드: 내부 배경색 없이 통일
              color: Colors.transparent,
                border: Border.all(color: borderColor, width: 2),
              borderRadius: BorderRadius.circular(12),
              ),
              child: attendedChild,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ValueListenableBuilder<int>(
              valueListenable: HomeworkStore.instance.revision,
              builder: (context, _rev, _) {
                return AnimatedBuilder(
                  animation: _uiAnimController,
                  builder: (context, _) {
                    return _buildHomeworkChipsScroller(t);
                  },
                );
              },
            ),
          ),
        ],
      );
    } else {
      return GestureDetector(
        key: key,
        onTap: () async {
          final now = DateTime.now();
          setState(() {
            if (status == 'waiting') {
              _attendedSetIds.add(t.setId);
              _attendTimes[t.setId] = now;
              _sideSheetDataDirty = true;
            } else if (status == 'attended') {
              _leavedSetIds.add(t.setId);
              _leaveTimes[t.setId] = now;
              _sideSheetDataDirty = true;
            }
          });
          try {
            final classDateTime = t.classDateTime;
            if (status == 'waiting') {
              await DataManager.instance.saveOrUpdateAttendance(
                studentId: t.student.id,
                classDateTime: classDateTime,
                classEndTime: classDateTime.add(t.duration),
                className: t.classInfo?.name ?? '수업',
                isPresent: true,
                arrivalTime: now,
                setId: t.setId,
                sessionTypeId: t.classInfo?.id,
              );
            } else if (status == 'attended') {
              final existing = DataManager.instance.getAttendanceRecord(t.student.id, classDateTime);
              if (existing != null) {
                // departureTime이 기록되면 출석으로 간주(isPresent=true)하여
                // arrival/departure는 있는데 isPresent=false로 남는 비정합을 방지한다.
                final updated = existing.copyWith(
                  departureTime: now,
                  isPresent: true,
                );
                try {
                  await DataManager.instance.updateAttendanceRecord(updated);
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('다른 기기에서 먼저 수정되었습니다. 새로고침 후 다시 시도하세요.')));
                }
              }
            }
          } catch (e) {
            print('[ERROR] 출석 기록 동기화 실패: $e');
          }
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: EdgeInsets.zero,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.transparent,
            border: Border.all(color: borderColor, width: 2),
            borderRadius: BorderRadius.circular(25),
          ),
          child: cardChild,
        ),
      );
    }
  }

  Widget _buildTrialLessonAttendanceCard(
    ConsultTrialLessonSlot s, {
    required String status, // 'waiting' | 'attended'
    Key? key,
    double scale = 1.0,
  }) {
    // 색상 규칙:
    // - waiting: 테두리만 시범(추가수업과 동일) 색상
    // - attended: 테두리는 시범 색상, 내부 배경 없음 (배지 없음)
    const trialGreen = Color(0xFF4CAF50);

    final nameStyle = TextStyle(
      color: status == 'attended' ? const Color(0xFFEAF2F2) : Colors.white70,
      // 기존 출석카드와 크기 통일
      fontSize: 16,
      fontWeight: FontWeight.w500,
    );

    if (status == 'attended') {
      // 기존 출석 카드(왼쪽 컨테이너 + 오른쪽 칩 영역) 레이아웃을 그대로 맞춘다.
      return Row(
        key: key,
        mainAxisSize: MainAxisSize.max,
        children: [
          GestureDetector(
            onTap: () {
              // 하원 처리
              unawaited(ConsultTrialLessonService.instance.setLeaved(slotId: s.id, leaved: true));
            },
            onSecondaryTap: () {
              // 실수 취소: 등원/하원 기록 제거
              unawaited(ConsultTrialLessonService.instance.setArrived(slotId: s.id, arrived: false));
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: EdgeInsets.zero,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.transparent,
                border: Border.all(color: trialGreen, width: 2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(s.title, style: nameStyle, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          const Expanded(child: SizedBox.shrink()),
        ],
      );
    }

    // waiting(등원 예정) 카드: 기존 waiting 카드(캡슐) 디자인을 그대로 사용
    return GestureDetector(
      key: key,
      onTap: () {
        unawaited(ConsultTrialLessonService.instance.setArrived(slotId: s.id, arrived: true));
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: EdgeInsets.zero,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.transparent,
          border: Border.all(color: trialGreen, width: 2),
          borderRadius: BorderRadius.circular(25),
        ),
        child: Text(
          s.title,
          style: nameStyle,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  List<Widget> _buildHomeworkChipsReactive(_AttendanceTarget t) {
    return [
      ValueListenableBuilder<int>(
        valueListenable: HomeworkStore.instance.revision,
        builder: (context, _rev, _) {
          return AnimatedBuilder(
            animation: _uiAnimController,
            builder: (context, _) {
              return _buildHomeworkChipsScroller(t);
            },
          );
        },
      )
    ];
  }

  // 가로 스크롤러: 칩이 넘치면 스크롤, 줄바꿈 금지
  Widget _buildHomeworkChipsScroller(_AttendanceTarget t) {
    final chips = _buildHomeworkChipsOnce(t);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Row(children: chips),
    );
  }

  List<Widget> _buildHomeworkChipsOnce(_AttendanceTarget t) {
    final List<Widget> chips = [];
    // 정렬: 수행(2/running) → 대기(1) → 확인(4) → 제출(3).
    // 동일 단계는 최초 생성 시각 빠른 순. 생성 시각 대용으로 firstStartedAt/confirmedAt/submittedAt/runStart/기타 nulls last 기준 사용
    List<HomeworkItem> hwList = List<HomeworkItem>.from(
      HomeworkStore.instance.items(t.student.id).where((e) => e.status != HomeworkStatus.completed),
    );
    DateTime? _ts(HomeworkItem e) => e.firstStartedAt ?? e.waitingAt ?? e.confirmedAt ?? e.submittedAt ?? e.runStart;
    int _phaseOrder(HomeworkItem e) {
      final running = HomeworkStore.instance.runningOf(t.student.id)?.id == e.id;
      if (running) return 0; // 수행 최우선
      switch (e.phase) {
        case 1: return 1; // 대기
        case 4: return 2; // 확인
        case 3: return 3; // 제출
        default: return 4;
      }
    }
    hwList.sort((a, b) {
      final oa = _phaseOrder(a);
      final ob = _phaseOrder(b);
      if (oa != ob) return oa - ob;
      final ta = _ts(a);
      final tb = _ts(b);
      if (ta == null && tb == null) return 0;
      if (ta == null) return 1;
      if (tb == null) return -1;
      return ta.compareTo(tb);
    });
    for (final hw in hwList) {
      if (chips.isNotEmpty) chips.add(const SizedBox(width: 8));
      chips.add(
        MouseRegion(
          onEnter: (e) {
            final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
            final offset = overlay.globalToLocal(e.position);
            _showTooltip(offset, hw.body.isEmpty ? '(내용 없음)' : hw.body);
          },
          onExit: (_) => _removeTooltip(),
          child: GestureDetector(
            onTap: () async {
              _activeStudentId = t.student.id;
              _activeItemId = hw.id;
              await _openHomeworkEditDialog(t.student.id, hw.id);
              if (mounted) setState(() {});
            },
            onLongPress: () async {
              // 활성화 지정 후 이어가기 다이얼로그 표시
              _activeStudentId = t.student.id;
              _activeItemId = hw.id;
              final res = await showDialog<Map<String, dynamic>?>(
                context: context,
                builder: (_) => HomeworkContinueDialog(studentId: t.student.id, title: hw.title, color: hw.color),
              );
              if (res != null && (res['body'] as String).isNotEmpty) {
                HomeworkStore.instance.continueAdd(t.student.id, hw.id, body: res['body'] as String);
                setState(() {});
              }
            },
            onSecondaryTap: () {
              // 활성화 지정 후 완료 처리
              _activeStudentId = t.student.id;
              _activeItemId = hw.id;
              unawaited(HomeworkStore.instance.complete(t.student.id, hw.id));
              setState(() {});
            },
            child: Builder(builder: (context) {
              final bool isRunning = (HomeworkStore.instance.runningOf(t.student.id)?.id == hw.id);
              final style = const TextStyle(
                color: Color(0xFFEAF2F2),
                fontSize: 14,
                fontWeight: FontWeight.w600,
                height: 1.1,
              );
              // 긴 제목도 잘리지 않도록 실제 텍스트 폭을 모두 반영
              final painter = TextPainter(
                text: TextSpan(text: hw.title, style: style),
                maxLines: 1,
                textDirection: TextDirection.ltr,
                textScaleFactor: MediaQuery.of(context).textScaleFactor,
              )..layout(minWidth: 0, maxWidth: double.infinity);
              final double textScale = MediaQuery.of(context).textScaleFactor;
              // 폰트 14 기준: 텍스트 영역을 더 확보하기 위해 패딩 축소
              const double leftPad = 14;
              const double rightPad = 16;
              // 활성화/비활성 상관없이 칩의 총 너비를 일정하게 유지하기 위해
              // 최대 테두리 두께(2px)를 기준으로 계산한다.
              const double borderWMax = 2.0;
              final double borderW = isRunning ? 2.0 : 1.0; // 실제 그릴 두께
              // 측정값 그대로 사용 + 소폭 여유치(6px)로 조기 ellipsis 방지
              final double width = painter.width + leftPad + rightPad + borderWMax * 2 + 6.0;
              if (!_chipDebugLogged.contains(hw.id)) {
                _chipDebugLogged.add(hw.id);
                debugPrint('[CHIP][measure] id=' + hw.id + ' title="' + hw.title + '" w=' + painter.width.toStringAsFixed(1) + ' scale=' + textScale.toStringAsFixed(2) + ' finalW=' + width.toStringAsFixed(1));
              }
              // 폰트 사이즈 증가를 고려하되, 지나친 최소폭은 줄임표를 유발하므로 완화
              final double minChipWidth = 70.0;
              // UI 전용 칩 상태
              final _UiPhase phase = _getUiPhase(t.student.id, hw.id);
              final double tick = _uiAnimController.value; // 0..1

              final textChild = Text(
                hw.title,
                style: style,
                textAlign: TextAlign.center,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
              );

              Widget chipInner = Container(
                height: 46,
                padding: const EdgeInsets.fromLTRB(leftPad, 0, rightPad, 0),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isRunning
                      ? Colors.transparent
                      : (phase == _UiPhase.confirmed
                          ? Color.lerp(const Color(0xFF2A2A2A), const Color(0xFF33393F), (0.5 + 0.5 * math.sin(2 * math.pi * tick)))
                          : const Color(0xFF2A2A2A)),
                  borderRadius: BorderRadius.circular(6),
                  border: isRunning
                      ? Border.all(color: hw.color.withOpacity(0.9), width: 2)
                      : (phase == _UiPhase.submitted ? null : Border.all(color: Colors.white24, width: borderW)),
                ),
                child: textChild,
              );

              if (!isRunning && phase == _UiPhase.submitted) {
                // 크기 변화 없이 회전 보더만 그리기: CustomPaint의 foregroundPainter 사용
                chipInner = RepaintBoundary(
                  child: CustomPaint(
                    // repaint를 애니메이션 컨트롤러에 직접 바인딩해 프레임마다 리페인트
                    foregroundPainter: _RotatingBorderPainter(
                      baseColor: hw.color,
                      tick: tick,
                      strokeWidth: 2.0,
                      cornerRadius: 6.0,
                    ),
                    child: chipInner,
                  ),
                );
              }

              return SizedBox(
                width: width.clamp(minChipWidth, 560.0),
                child: chipInner,
              );
            }),
          ),
        ),
      );
    }
    return chips;
  }
}

class _TodayDateLabel extends StatelessWidget {
  const _TodayDateLabel();
  @override
  Widget build(BuildContext context) {
    return Text(
      _getTodayDateString(),
      style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w800),
    );
  }
}

// 출석 대상 학생 정보 구조체
class _AttendanceTarget {
  final String setId;
  final Student student;
  final ClassInfo? classInfo;
  // ✅ "오늘"을 now로 재구성하지 않고, 실제 attendance_records의 class_date_time(로컬)을 그대로 보존
  // - 이 값으로 saveOrUpdateAttendance를 호출해야 planned 행을 안정적으로 업데이트한다.
  // - now.year/month/day로 재구성하면 날짜 경계(자정), 타임존/로컬 변환, 캐시 타이밍에 따라
  //   planned 행 매칭이 실패하여 동일 시각 중복 INSERT가 발생할 수 있다.
  final DateTime classDateTime;
  final Duration duration;
  final OverrideType? overrideType; // null이면 일반 수업, replace=보강(파란줄), add=추가수업(초록줄)

  _AttendanceTarget({
    required this.setId,
    required this.student,
    required this.classInfo,
    required this.classDateTime,
    required this.duration,
    this.overrideType,
  });

  int get startHour => classDateTime.hour;
  int get startMinute => classDateTime.minute;
  DateTime get startTime => classDateTime;
}

class _LeavedDialogEntry {
  final _AttendanceTarget target;
  final DateTime? arrival;
  final DateTime? departure;

  const _LeavedDialogEntry({required this.target, this.arrival, this.departure});
}

// OverlayEntry 툴팁을 띄우는 호버 영역 위젯
class _TooltipHoverArea extends StatefulWidget {
  final String main;
  final String tooltip;
  final Color textColor;
  final void Function(BuildContext, Offset, String) showTooltip;
  final VoidCallback hideTooltip;
  const _TooltipHoverArea({required this.main, required this.tooltip, required this.showTooltip, required this.hideTooltip, required this.textColor});
  @override
  State<_TooltipHoverArea> createState() => _TooltipHoverAreaState();
}
class _TooltipHoverAreaState extends State<_TooltipHoverArea> {
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (event) {
        final renderBox = context.findRenderObject() as RenderBox?;
        final offset = renderBox?.localToGlobal(Offset.zero) ?? Offset.zero;
        widget.showTooltip(context, offset, widget.tooltip);
      },
      onExit: (_) => widget.hideTooltip(),
      child: Text(
        widget.main,
        style: TextStyle(color: widget.textColor, fontSize: 16, fontWeight: FontWeight.w500),
      ),
    );
  }
}

String _formatTime(DateTime dt) {
  return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
} 

// 날짜/요일 포맷 함수 추가
String _getTodayDateString() {
  final now = DateTime.now();
  final week = ['월', '화', '수', '목', '금', '토', '일'];
  return '${now.year}.${now.month.toString().padLeft(2, '0')}.${now.day.toString().padLeft(2, '0')} (${week[now.weekday - 1]})';
} 

// 수업 태그 정의(메모리 전용)
class _ClassTag {
  final String name;
  final Color color;
  final IconData icon;
  const _ClassTag({required this.name, required this.color, required this.icon});
}

// UI 전용 칩 상태 정의
enum _UiPhase {
  // 수행 상태는 서버 running 여부로 표현, 아래 값들은 UI 전용 표시 상태
  submitted, // 제출: 회전 테두리
  confirmed, // 확인: 깜빡임
  waiting,   // 대기: 비활성화
}
// 태그 이벤트: 태그 + 적용 시각
class _ClassTagEvent {
  final _ClassTag tag;
  final DateTime timestamp;
  final String? note; // '기록' 등 메모성 태그용 텍스트
  const _ClassTagEvent({required this.tag, required this.timestamp, this.note});
}

extension on _MainScreenState {
  // UI 전용 칩 상태(enum) 유틸
  _UiPhase _getUiPhase(String studentId, String itemId) {
    // 스토어 값 우선 (서버 동기화 상태 반영)
    final item = HomeworkStore.instance.getById(studentId, itemId);
    final running = (HomeworkStore.instance.runningOf(studentId)?.id == itemId);
    if (running) {
      // running이면 UI에선 수행 표시(파란 테두리는 chipInner에서 별도 처리)
      return _UiPhase.waiting; // 수행은 전용 테두리로 표현하고 phase 맵은 제출/확인/대기만 사용
    }
    if (item != null) {
      switch (item.phase) {
        case 3: // 제출
          return _UiPhase.submitted;
        case 4: // 확인
          return _UiPhase.confirmed;
        case 1: // 대기
        case 0: // 종료 → UI에서는 대기 같은 비활성로 표현
        default:
          return _UiPhase.waiting;
      }
    }
    // 로컬 UI 전용 맵은 보조 용도로 유지
    final byItem = _uiPhases[studentId];
    if (byItem == null) return _UiPhase.waiting;
    return byItem[itemId] ?? _UiPhase.waiting;
  }

  void _setUiPhase(String studentId, String itemId, _UiPhase phase) {
    setState(() {
      _uiPhases.putIfAbsent(studentId, () => <String, _UiPhase>{})[itemId] = phase;
    });
  }

  Future<void> _openHomeworkEditDialog(String studentId, String itemId) async {
    final item = HomeworkStore.instance.getById(studentId, itemId);
    if (item == null) return;
    final edited = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => HomeworkEditDialog(initialTitle: item.title, initialBody: item.body, initialColor: item.color),
    );
    if (edited == null) return;
    final updated = HomeworkItem(
      id: item.id,
      title: (edited['title'] as String).trim(),
      body: (edited['body'] as String).trim(),
      color: (edited['color'] as Color),
      status: item.status,
      phase: item.phase,
      accumulatedMs: item.accumulatedMs,
      runStart: item.runStart,
      completedAt: item.completedAt,
      firstStartedAt: item.firstStartedAt,
      submittedAt: item.submittedAt,
      confirmedAt: item.confirmedAt,
      waitingAt: item.waitingAt,
      version: item.version,
    );
    HomeworkStore.instance.edit(studentId, updated);
  }

  // 임시 A/B 버튼 핸들러 제거됨
  Future<void> _openClassTagDialog(_AttendanceTarget target) async {
    final List<_ClassTagEvent> initialApplied = List<_ClassTagEvent>.from(_classTagEventsBySetId[target.setId] ?? const []);
    List<_ClassTagEvent> workingApplied = List<_ClassTagEvent>.from(initialApplied);
    // 프리셋에서 즉시 로드하여 사용 가능한 태그 구성
    final presets = await TagPresetService.instance.loadPresets();
    List<_ClassTag> workingAvailable = presets
        .map((p) => _ClassTag(name: p.name, color: p.color, icon: p.icon))
        .toList();

    _ClassTag? newTag;

    List<_ClassTagEvent>? result = await showDialog<List<_ClassTagEvent>>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            Future<void> _handleTagPressed(_ClassTag tag) async {
              final now = DateTime.now();
              String? note;
              if (tag.name == '기록') {
                note = await _openRecordNoteDialog(ctx);
                if (note == null || note.trim().isEmpty) return;
              }
              // 즉시 메모리 반영
              setLocal(() {
                workingApplied.add(_ClassTagEvent(tag: tag, timestamp: now, note: note?.trim()));
              });
              // 즉시 서버/로컬 저장 (학생ID 포함)
              TagStore.instance.appendEvent(target.setId, target.student.id, TagEvent(
                tagName: tag.name,
                colorValue: tag.color.value,
                iconCodePoint: tag.icon.codePoint,
                timestamp: now,
                note: note?.trim(),
              ));
            }

            Widget _buildAvailableTagChip(_ClassTag tag) {
              return ActionChip(
                onPressed: () => _handleTagPressed(tag),
                backgroundColor: const Color(0xFF2A2A2A),
                label: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(tag.icon, color: tag.color, size: 18),
                    const SizedBox(width: 6),
                    Text(tag.name, style: const TextStyle(color: Colors.white70)),
                  ],
                ),
                shape: StadiumBorder(side: BorderSide(color: tag.color.withOpacity(0.6), width: 1.0)),
              );
            }

            return AlertDialog(
              backgroundColor: const Color(0xFF0B1112),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              title: const Text('수업 태그', style: TextStyle(color: Colors.white, fontSize: 20)),
              content: SizedBox(
                width: 560,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(target.student.name + ' · ' + _getTodayDateString(), style: const TextStyle(color: Colors.white54, fontSize: 13)),
                      const SizedBox(height: 12),
                      const Text('적용된 태그', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      if (workingApplied.isEmpty)
                        const Text('아직 추가된 태그가 없습니다.', style: TextStyle(color: Colors.white38))
                      else
                        Column(
                          children: [
                            for (int i = workingApplied.length - 1; i >= 0; i--) ...[
                              Builder(builder: (context) {
                                final e = workingApplied[i];
                                return Container(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF22262C),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: e.tag.color.withOpacity(0.35), width: 1),
                                  ),
                                  child: Row(
                                    children: [
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(e.tag.icon, color: e.tag.color, size: 18),
                                          const SizedBox(width: 8),
                                          Text(e.tag.name, style: const TextStyle(color: Colors.white70)),
                                          if (e.note != null && e.note!.isNotEmpty) ...[
                                            const SizedBox(width: 8),
                                            Text(e.note!, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                                          ],
                                        ],
                                      ),
                                      const Spacer(),
                                      Text(_formatTime(e.timestamp), style: const TextStyle(color: Colors.white54, fontSize: 12)),
                                      const SizedBox(width: 8),
                                      InkWell(
                                        onTap: () {
                                          setLocal(() {
                                            workingApplied.removeAt(i);
                                          });
                                        },
                                        child: const Icon(Icons.close, color: Colors.white54, size: 16),
                                      ),
                                    ],
                                  ),
                                );
                              }),
                            ],
                          ],
                        ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          const Text('추가 가능한 태그', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold)),
                          const Spacer(),
                          // '새 태그 만들기' 버튼 제거: 태그 프리셋 관리에서 추가하도록 유도
                          const SizedBox(width: 8),
                          IconButton(
                            tooltip: '태그 관리',
                            onPressed: () async {
                          await showDialog(
                                context: context,
                                builder: (_) => const TagPresetDialog(),
                              );
                          // 태그 프리셋 변경 즉시 반영: 프리셋 재로드 후 갱신
                          final refreshed = await TagPresetService.instance.loadPresets();
                          setLocal(() {
                            workingAvailable = refreshed
                                .map((p) => _ClassTag(name: p.name, color: p.color, icon: p.icon))
                                .toList();
                          });
                            },
                            icon: const Icon(Icons.style, color: Colors.white70),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: workingAvailable.map(_buildAvailableTagChip).toList(),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(workingApplied),
                  child: const Text('닫기', style: TextStyle(color: Colors.white70)),
                ),
              ],
            );
          },
        );
      },
    );

    if (result != null) {
      setState(() {
        _classTagEventsBySetId[target.setId] = result!;
      });
      // 동기화: 학습 > 기록 타임라인에서 표시되도록 전역 TagStore에 반영
      final events = result!.map((e) => TagEvent(
        tagName: e.tag.name,
        colorValue: e.tag.color.value,
        iconCodePoint: e.tag.icon.codePoint,
        timestamp: e.timestamp,
        note: e.note,
      )).toList();
      TagStore.instance.setEventsForSet(target.setId, target.student.id, events);
    }
  }

  Future<_ClassTag?> _createNewClassTag(BuildContext context) async {
    final TextEditingController nameController = ImeAwareTextEditingController();
    final List<Color> palette = const [
      Color(0xFFEF5350), Color(0xFFAB47BC), Color(0xFF7E57C2), Color(0xFF5C6BC0),
      Color(0xFF42A5F5), Color(0xFF26A69A), Color(0xFF66BB6A), Color(0xFFFFCA28),
      Color(0xFFF57C00), Color(0xFF8D6E63), Color(0xFFBDBDBD), Color(0xFF90A4AE),
    ];
    final List<IconData> iconChoices = const [
      Icons.bedtime, Icons.phone_iphone, Icons.edit_note, Icons.lightbulb, Icons.flag,
      Icons.psychology, Icons.sports_esports, Icons.timer, Icons.warning, Icons.check_circle,
      Icons.book, Icons.menu_book, Icons.school, Icons.sick, Icons.mood_bad, Icons.thumb_down,
      Icons.thumb_up, Icons.self_improvement, Icons.local_cafe, Icons.code,
    ];

    Color selectedColor = palette[2];
    IconData selectedIcon = iconChoices.first;

    final _ClassTag? created = await showDialog<_ClassTag?>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              backgroundColor: const Color(0xFF0B1112),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              title: const Text('새 태그 만들기', style: TextStyle(color: Colors.white, fontSize: 20)),
              content: SizedBox(
                width: 520,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('이름', style: TextStyle(color: Colors.white70)),
                      const SizedBox(height: 6),
                      TextField(
                        controller: nameController,
                        decoration: const InputDecoration(
                          hintText: '예: 집중 저하',
                          hintStyle: TextStyle(color: Colors.white38),
                          filled: true,
                          fillColor: Color(0xFF2A2A2A),
                          border: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                          enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                          focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
                        ),
                        style: const TextStyle(color: Colors.white),
                      ),
                      const SizedBox(height: 16),
                      const Text('색상', style: TextStyle(color: Colors.white70)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final c in palette)
                            GestureDetector(
                              onTap: () => setLocal(() => selectedColor = c),
                              child: Container(
                                width: 28,
                                height: 28,
                                decoration: BoxDecoration(
                                  color: c,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: c == selectedColor ? Colors.white : Colors.white24, width: c == selectedColor ? 2 : 1),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const Text('아이콘', style: TextStyle(color: Colors.white70)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final ic in iconChoices)
                            GestureDetector(
                              onTap: () => setLocal(() => selectedIcon = ic),
                              child: Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF2A2A2A),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: ic == selectedIcon ? Colors.white : Colors.white24),
                                ),
                                child: Icon(ic, color: ic == selectedIcon ? Colors.white : Colors.white70, size: 20),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(null),
                  child: const Text('취소', style: TextStyle(color: Colors.white70)),
                ),
                ElevatedButton(
                  onPressed: () {
                    final name = nameController.text.trim();
                    if (name.isEmpty) {
                      Navigator.of(ctx).pop(null);
                      return;
                    }
                    Navigator.of(ctx).pop(_ClassTag(name: name, color: selectedColor, icon: selectedIcon));
                  },
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1976D2), foregroundColor: Colors.white),
                  child: const Text('추가'),
                ),
              ],
            );
          },
        );
      },
    );

    return created;
  }

  Future<String?> _openRecordNoteDialog(BuildContext context) async {
    final TextEditingController controller = ImeAwareTextEditingController();
    return showDialog<String?>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF0B1112),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          title: const Text('기록 입력', style: TextStyle(color: Colors.white, fontSize: 20)),
          content: SizedBox(
            width: 520,
            child: TextField(
              controller: controller,
              maxLines: 4,
              decoration: const InputDecoration(
                hintText: '수업 중 있었던 일을 간단히 적어주세요',
                hintStyle: TextStyle(color: Colors.white38),
                filled: true,
                fillColor: Color(0xFF2A2A2A),
                border: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
              ),
              style: const TextStyle(color: Colors.white),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('취소', style: TextStyle(color: Colors.white70)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1976D2), foregroundColor: Colors.white),
              child: const Text('저장'),
            ),
          ],
        );
      },
    );
  }
}

// 회전 보더 페인터: 내부 child의 레이아웃을 바꾸지 않고, 외곽선만 회전시키며 그린다
class _RotatingBorderPainter extends CustomPainter {
  final Color baseColor;
  final double tick; // 0..1
  final double strokeWidth;
  final double cornerRadius;
  _RotatingBorderPainter({required this.baseColor, required this.tick, this.strokeWidth = 2.0, this.cornerRadius = 8.0}) : super();
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectXY(rect.deflate(strokeWidth / 2), cornerRadius, cornerRadius);
    // 원형(라운드) 경로를 따라 그라디언트 스트로크를 회전
    final sweepShader = SweepGradient(
      startAngle: 0.0,
      endAngle: 2 * math.pi,
      transform: GradientRotation(2 * math.pi * tick),
      colors: [
        baseColor.withOpacity(0.1),
        baseColor.withOpacity(0.9),
        baseColor.withOpacity(0.1),
      ],
      stops: const [0.0, 0.5, 1.0],
    ).createShader(rect);
    final paint = Paint()
      ..shader = sweepShader
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..isAntiAlias = true;
    canvas.drawRRect(rrect, paint);
  }
  @override
  bool shouldRepaint(covariant _RotatingBorderPainter oldDelegate) {
    return oldDelegate.tick != tick || oldDelegate.baseColor != baseColor || oldDelegate.strokeWidth != strokeWidth || oldDelegate.cornerRadius != cornerRadius;
  }
}

