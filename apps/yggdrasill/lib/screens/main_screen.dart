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
import '../app_overlays.dart';
import '../models/class_info.dart';
import '../models/session_override.dart';
import '../models/student_time_block.dart';
import 'dart:collection';
import 'dart:math' as math;
import '../models/education_level.dart';
import 'package:collection/collection.dart';
import '../services/homework_store.dart';
import '../services/homework_assignment_store.dart';
import '../services/consult_trial_lesson_service.dart';
import '../services/student_flow_store.dart';
import '../services/student_behavior_assignment_store.dart';
import 'learning/homework_quick_add_proxy_dialog.dart';
import 'learning/homework_edit_dialog.dart';
import 'class_content_events_dialog.dart';
import 'timetable/components/student_time_info_dialog.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';
import 'timetable/views/makeup_view.dart';
import '../widgets/dialog_tokens.dart';
import '../widgets/dark_panel_route.dart';
import '../widgets/flow_setup_dialog.dart';
import '../widgets/homework_assign_dialog.dart';
import '../widgets/left_side_sheet/favorite_templates_panel.dart';
import '../widgets/textbook_flow_link_action.dart';
import 'student/student_profile_page.dart';
import '../app_overlays.dart';
import '../models/behavior_card_drag_payload.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

enum _SideSheetBottomView { waiting, allStudents, favoriteTemplates }

class _MainScreenState extends State<MainScreen> with TickerProviderStateMixin {
  // 디버그 로그 스위치 (사이드 시트 출석 분류)
  // ✅ 기본 OFF: 사이드 시트/출석 쪽 대량 로그는 UI 스레드를 막아 렉을 유발할 수 있음(특히 Windows).
  // 필요 시 실행 옵션으로만 활성화:
  // flutter run ... --dart-define=YG_SIDE_SHEET_DEBUG=true
  static const bool _sideSheetDebug = bool.fromEnvironment(
    'YG_SIDE_SHEET_DEBUG',
    defaultValue: false,
  );
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
  DateTime _sideSheetAnchorDate = DateTime(
    DateTime.now().year,
    DateTime.now().month,
    DateTime.now().day,
  );
  List<_AttendanceTarget> _cachedWaiting = const [];
  List<_AttendanceTarget> _cachedAttended = const [];
  List<_AttendanceTarget> _cachedLeaved = const [];
  Map<String, DateTime?> _arrivalBySetCache = const {};
  Map<String, DateTime?> _departureBySetCache = const {};
  Map<DateTime, List<_AttendanceTarget>> _waitingByTimeCache = SplayTreeMap();
  _SideSheetBottomView _sideSheetBottomView = _SideSheetBottomView.waiting;
  final Map<String, bool> _allStudentsExpandedByGrade = <String, bool>{};
  final Map<String, GlobalKey> _allStudentsGradeAnchorKeys =
      <String, GlobalKey>{};
  late final ScrollController _attendedScrollCtrl;
  late final ScrollController _waitingScrollCtrl;

  // StudentScreen 관련 상태
  final GlobalKey<StudentScreenState> _studentScreenKey =
      GlobalKey<StudentScreenState>();
  StudentViewType _viewType = StudentViewType.all;
  final List<GroupInfo> _groups = [];
  final List<Student> _students = [];
  final TextEditingController _searchController =
      ImeAwareTextEditingController();
  String _searchQuery = '';
  final Set<GroupInfo> _expandedGroups = {};
  double _fabBottomPadding = 16.0;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>?
      _snackBarController;
  int? _prevIndex;
  // UI 전용: 과제 칩 상태(학생ID->아이템ID->상태) & 활성 항목
  final Map<String, Map<String, _UiPhase>> _uiPhases = {};
  String? _activeStudentId;
  String? _activeItemId;
  // 진단 로그: 애니메이션/칩 측정
  int _animDebugCounter = 0;
  Timer? _animLogTimer;
  final Set<String> _chipDebugLogged = <String>{};
  final Map<String, int> _homeworkChipAssignRevisionByStudent = <String, int>{};
  final Map<String, Future<List<HomeworkAssignmentDetail>>>
      _activeAssignmentsFutureByStudent =
      <String, Future<List<HomeworkAssignmentDetail>>>{};

  // 출석/하원 상태 관리
  final Set<String> _attendedSetIds = {}; // 출석한 setId
  final Set<String> _leavedSetIds = {}; // 하원한 setId
  double _sideSheetWidth = 0.0;
  final GlobalKey _sideSheetKey = GlobalKey();
  Offset? _lastTagTapPosition;

  DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
  bool _isSameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  void _moveSideSheetToYesterday() {
    final today = _dateOnly(DateTime.now());
    final yesterday = today.subtract(const Duration(days: 1));
    if (_isSameDate(_sideSheetAnchorDate, yesterday)) return;
    setState(() {
      _sideSheetAnchorDate = yesterday;
      _sideSheetDataDirty = true;
    });
  }

  void _moveSideSheetToToday() {
    final today = _dateOnly(DateTime.now());
    if (_isSameDate(_sideSheetAnchorDate, today)) return;
    setState(() {
      _sideSheetAnchorDate = today;
      _sideSheetDataDirty = true;
    });
  }

  // 기준 날짜의 등원 대상 학생(setId별) 리스트 추출
  List<_AttendanceTarget> getAttendanceTargetsForDate(
    DateTime anchorDate, [
    List<AttendanceRecord>? records,
    Map<String, AttendanceRecord>? outRecordBySet,
  ]) {
    final source = records ?? DataManager.instance.attendanceRecords;
    final anchor = _dateOnly(anchorDate);
    if (_sideSheetDebug) {
      final dayCount = source.where((r) {
        final dt = r.classDateTime;
        return dt.year == anchor.year &&
            dt.month == anchor.month &&
            dt.day == anchor.day;
      });
      final presentCnt = dayCount.where((r) => r.isPresent).length;
      final arrivedCnt = dayCount.where((r) => r.arrivalTime != null).length;
      final plannedCnt = dayCount.where((r) => r.isPlanned).length;
      debugPrint(
        '[SIDE][records] date=$anchor count=${dayCount.length} present=$presentCnt arrival=$arrivedCnt planned=$plannedCnt',
      );
      final samplePresent =
          dayCount.where((r) => r.isPresent || r.arrivalTime != null).take(5);
      for (final r in samplePresent) {
        debugPrint(
          '[SIDE][records][sample-present] student=${r.studentId} setId=${r.setId} dt=${r.classDateTime} arr=${r.arrivalTime} dep=${r.departureTime} isPlanned=${r.isPlanned} id=${r.id}',
        );
      }
    }
    String minuteKey(DateTime d) =>
        '${d.year}-${d.month}-${d.day}-${d.hour}-${d.minute}';
    final Set<String> hiddenOriginalPlannedKeys = <String>{};
    for (final o in DataManager.instance.sessionOverrides) {
      if (o.reason != OverrideReason.makeup) continue;
      if (o.overrideType != OverrideType.replace) continue;
      if (o.status == OverrideStatus.canceled) continue;
      final orig = o.originalClassDateTime;
      if (orig == null) continue;
      if (orig.year != anchor.year ||
          orig.month != anchor.month ||
          orig.day != anchor.day) {
        continue;
      }
      hiddenOriginalPlannedKeys.add('${o.studentId}|${minuteKey(orig)}');
    }
    // setId별로 "가장 이른 수업 시간" 하나만 대표로 사용 (실제 등원 기록이 있으면 우선 선택)
    final Map<String, AttendanceRecord> earliestBySet = {};
    int todayTotal = 0;
    int directSetId = 0;
    int resolvedSetId = 0;
    int failedSetId = 0;
    for (final r in source) {
      final dt = r.classDateTime;
      if (dt.year != anchor.year ||
          dt.month != anchor.month ||
          dt.day != anchor.day) continue;
      if (r.isPlanned == true &&
          !r.isPresent &&
          r.arrivalTime == null &&
          r.departureTime == null) {
        final key = '${r.studentId}|${minuteKey(dt)}';
        if (hiddenOriginalPlannedKeys.contains(key)) {
          if (_sideSheetDebug) {
            debugPrint(
              '[SIDE][skip-planned] overridden original student=${r.studentId} dt=$dt',
            );
          }
          continue;
        }
      }
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
          debugPrint(
            '[SIDE][skip] setId null student=${r.studentId} dt=$dt recId=${r.id}',
          );
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
          } else if (prevPlanned == curPlanned &&
              dt.isBefore(prev.classDateTime)) {
            preferCurrent = true;
          }
        } else if (prevHasAttendance == curHasAttendance &&
            dt.isBefore(prev.classDateTime)) {
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
      final studentInfo = DataManager.instance.students.firstWhereOrNull(
        (s) => s.student.id == r.studentId,
      );
      if (studentInfo == null) continue;
      ClassInfo? classInfo;
      if (r.sessionTypeId != null) {
        classInfo = DataManager.instance.classes.firstWhereOrNull(
          (c) => c.id == r.sessionTypeId,
        );
      }
      final duration = r.classEndTime.difference(r.classDateTime);
      targets.add(
        _AttendanceTarget(
          setId: entry.key,
          student: studentInfo.student,
          classInfo: classInfo,
          classDateTime: dt,
          duration: duration,
          overrideType: null,
        ),
      );
    }
    targets.sort((a, b) => a.startTime.compareTo(b.startTime));
    return targets;
  }

  String? _resolveSetIdFromTime(String studentId, DateTime classDateTime) {
    final blocks = DataManager.instance.studentTimeBlocks;
    final dayIdx = classDateTime.weekday - 1;
    final targetDate = DateTime(
      classDateTime.year,
      classDateTime.month,
      classDateTime.day,
    );

    bool isActiveOnDate(StudentTimeBlock b) {
      final sd = DateTime(b.startDate.year, b.startDate.month, b.startDate.day);
      final ed = b.endDate == null
          ? null
          : DateTime(b.endDate!.year, b.endDate!.month, b.endDate!.day);
      return !sd.isAfter(targetDate) &&
          (ed == null || !ed.isBefore(targetDate));
    }

    final candidates = blocks
        .where(
          (b) =>
              b.studentId == studentId &&
              b.dayIndex == dayIdx &&
              b.startHour == classDateTime.hour &&
              b.startMinute == classDateTime.minute &&
              isActiveOnDate(b) &&
              b.setId != null &&
              b.setId!.isNotEmpty,
        )
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
      debugPrint(
        '[SIDE][dirty] t=${now.toIso8601String()} len=$len anim=$anim',
      );
    }
  }

  void _recomputeSideSheetCache(List<AttendanceRecord> records) {
    final Map<String, AttendanceRecord> recordBySet = {};
    final attendanceTargets = getAttendanceTargetsForDate(
      _sideSheetAnchorDate,
      records,
      recordBySet,
    );

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
    const _ClassTag(
      name: '스마트폰',
      color: Color(0xFFF57C00),
      icon: Icons.phone_iphone,
    ),
    const _ClassTag(
      name: '떠듬',
      color: Color(0xFFEF5350),
      icon: Icons.record_voice_over,
    ),
    const _ClassTag(name: '딴짓', color: Color(0xFF90A4AE), icon: Icons.gesture),
    const _ClassTag(
      name: '기록',
      color: Color(0xFF1976D2),
      icon: Icons.edit_note,
    ),
  ];

  // OverlayEntry 툴팁 상태
  OverlayEntry? _tooltipOverlay;
  OverlayEntry? _classTagOverlay;
  final ValueNotifier<bool> _classTagBarrierActive = ValueNotifier<bool>(true);
  Timer? _classTagBarrierTimer;
  Timer? _attendedTapTimer;
  DateTime? _lastAttendedTapAt;
  String? _lastAttendedTapSetId;
  static const Duration _doubleTapWindow = Duration(milliseconds: 260);
  // 더블클릭과 단일 클릭을 확실히 분리하기 위해 동일 윈도우로 지연
  static const Duration _overlayOpenDelay = _doubleTapWindow;
  void _removeClassTagOverlay() {
    _classTagOverlay?.remove();
    _classTagOverlay = null;
    _classTagBarrierTimer?.cancel();
    _classTagBarrierActive.value = true;
  }

  Rect? _getSideSheetRect() {
    final ctx = _sideSheetKey.currentContext;
    if (ctx == null) return null;
    final box = ctx.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    final pos = box.localToGlobal(Offset.zero);
    return pos & box.size;
  }

  bool get _hasActiveStudentDropPayload =>
      activeTextbookDragPayload.value != null ||
      activeBehaviorCardDragPayload.value != null;

  void _syncSideSheetHoverState(bool hovering) {
    final bool hasTextbookPayload = activeTextbookDragPayload.value != null;
    if (hasTextbookPayload &&
        isTextbookDraggingOverLeftSideSheet.value != hovering) {
      isTextbookDraggingOverLeftSideSheet.value = hovering;
    }
    final bool hasBehaviorPayload = activeBehaviorCardDragPayload.value != null;
    if (hasBehaviorPayload &&
        isBehaviorDraggingOverLeftSideSheet.value != hovering) {
      isBehaviorDraggingOverLeftSideSheet.value = hovering;
    }
    if (!hasTextbookPayload && isTextbookDraggingOverLeftSideSheet.value) {
      isTextbookDraggingOverLeftSideSheet.value = false;
    }
    if (!hasBehaviorPayload && isBehaviorDraggingOverLeftSideSheet.value) {
      isBehaviorDraggingOverLeftSideSheet.value = false;
    }
  }

  Widget _wrapSideSheetDragHoverTarget({required Widget child}) {
    return DragTarget<Object>(
      onWillAccept: (_) => _hasActiveStudentDropPayload,
      onMove: (_) => _syncSideSheetHoverState(true),
      onLeave: (_) => _syncSideSheetHoverState(false),
      onAcceptWithDetails: (_) => _syncSideSheetHoverState(false),
      builder: (context, candidateData, rejectedData) => child,
    );
  }

  Future<void> _handleTextbookDropForStudent(String studentId) async {
    final payload = activeTextbookDragPayload.value;
    if (payload == null) return;
    await linkDraggedTextbookToStudentFlow(
      context: context,
      studentId: studentId,
      payload: payload,
    );
    _syncSideSheetHoverState(false);
  }

  Future<void> _handleBehaviorDropForStudent(
    String studentId,
    BehaviorCardDragPayload payload,
  ) async {
    try {
      await StudentBehaviorAssignmentStore.instance.upsertFromDrop(
        studentId: studentId,
        payload: payload,
      );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(content: Text('${payload.name} 행동을 학생에게 부여했어요.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('행동 부여에 실패했어요: $e')));
    } finally {
      activeBehaviorCardDragPayload.value = null;
      _syncSideSheetHoverState(false);
    }
  }

  Widget _wrapTextbookDropTargetForStudent({
    required String studentId,
    required Widget child,
  }) {
    return DragTarget<Object>(
      onWillAccept: (_) => _hasActiveStudentDropPayload,
      onMove: (_) => _syncSideSheetHoverState(true),
      onLeave: (_) => _syncSideSheetHoverState(false),
      onAcceptWithDetails: (_) {
        final behaviorPayload = activeBehaviorCardDragPayload.value;
        if (behaviorPayload != null) {
          unawaited(_handleBehaviorDropForStudent(studentId, behaviorPayload));
          return;
        }
        if (activeTextbookDragPayload.value != null) {
          unawaited(_handleTextbookDropForStudent(studentId));
        }
      },
      builder: (context, candidateData, rejectedData) {
        final bool hovering =
            candidateData.isNotEmpty && _hasActiveStudentDropPayload;
        if (!hovering) return child;
        final Color lineColor = activeBehaviorCardDragPayload.value != null
            ? const Color(0xFF8D7CFF)
            : const Color(0xFF33A373);
        return Stack(
          fit: StackFit.passthrough,
          children: [
            child,
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                child: SizedBox(
                  height: 2,
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: lineColor),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _showTooltip(Offset position, String text) {
    // print('[DEBUG] _showTooltip called: position= [38;5;246m$position [0m, text=$text');
    _removeTooltip();
    final overlay = Overlay.of(context);
    _tooltipOverlay = OverlayEntry(
      builder: (context) => Positioned(
        left: position.dx + 12, // 마우스 오른쪽 약간 띄움
        top: position.dy + 12, // 마우스 아래 약간 띄움
        // 툴팁이 마우스 이벤트를 가로채지 않도록 한다.
        // (onExit 누락/히트테스트 흔들림으로 툴팁이 남는 현상 완화)
        child: IgnorePointer(
          ignoring: true,
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
      ),
    );
    overlay.insert(_tooltipOverlay!);
    // print('[DEBUG] _showTooltip OverlayEntry inserted');
  }

  void _armClassTagBarrier() {
    _classTagBarrierTimer?.cancel();
    _classTagBarrierActive.value = false;
    _classTagBarrierTimer = Timer(_doubleTapWindow, () {
      if (_classTagOverlay == null) return;
      _classTagBarrierActive.value = true;
    });
  }

  Future<void> _openStudentProfile(StudentWithInfo info) async {
    final flows = await StudentFlowStore.instance.loadForStudent(
      info.student.id,
    );
    if (!mounted) return;
    Navigator.of(context).push(
      DarkPanelRoute(
        child: StudentProfilePage(studentWithInfo: info, flows: flows),
      ),
    );
  }

  Future<void> _openStudentProfileFromAttendance(
    _AttendanceTarget target,
  ) async {
    final info = DataManager.instance.students.firstWhereOrNull(
      (s) => s.student.id == target.student.id,
    );
    if (info == null) return;
    await _openStudentProfile(info);
  }

  void _handleAttendedCardTap(_AttendanceTarget target) {
    final now = DateTime.now();
    final last = _lastAttendedTapAt;
    if (last != null &&
        _lastAttendedTapSetId == target.setId &&
        now.difference(last) <= _doubleTapWindow) {
      _attendedTapTimer?.cancel();
      _attendedTapTimer = null;
      _lastAttendedTapAt = null;
      _lastAttendedTapSetId = null;
      _removeClassTagOverlay();
      unawaited(_openStudentProfileFromAttendance(target));
      return;
    }
    _lastAttendedTapAt = now;
    _lastAttendedTapSetId = target.setId;
    _attendedTapTimer?.cancel();
    _attendedTapTimer = Timer(_overlayOpenDelay, () {
      if (!mounted) return;
      _openClassTagDialog(target, anchor: _lastTagTapPosition);
    });
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
  static double get _allStudentsListRowHeight => (_cardActualHeight * 1.3) + 12;

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

  static String _educationLevelPrefix(EducationLevel level) {
    switch (level) {
      case EducationLevel.elementary:
        return '초';
      case EducationLevel.middle:
        return '중';
      case EducationLevel.high:
        return '고';
    }
  }

  Map<String, List<StudentWithInfo>> _groupStudentsByGradeForSideSheet(
    List<StudentWithInfo> students,
  ) {
    final Map<String, List<StudentWithInfo>> grouped =
        <String, List<StudentWithInfo>>{};
    for (final s in students) {
      final key =
          '${_educationLevelPrefix(s.student.educationLevel)}${s.student.grade}';
      grouped.putIfAbsent(key, () => <StudentWithInfo>[]).add(s);
    }

    for (final list in grouped.values) {
      list.sort((a, b) => a.student.name.compareTo(b.student.name));
    }

    int levelOrder(String key) {
      if (key.startsWith('초')) return 0;
      if (key.startsWith('중')) return 1;
      if (key.startsWith('고')) return 2;
      return 3;
    }

    int gradeNum(String key) {
      final m = RegExp(r'\d+').firstMatch(key);
      if (m == null) return 0;
      return int.tryParse(m.group(0)!) ?? 0;
    }

    final sortedKeys = grouped.keys.toList()
      ..sort((a, b) {
        final byLevel = levelOrder(a).compareTo(levelOrder(b));
        if (byLevel != 0) return byLevel;
        return gradeNum(a).compareTo(gradeNum(b));
      });
    return <String, List<StudentWithInfo>>{
      for (final k in sortedKeys) k: grouped[k]!,
    };
  }

  void _toggleSideSheetBottomView() {
    setState(() {
      if (_sideSheetBottomView != _SideSheetBottomView.allStudents) {
        _sideSheetBottomView = _SideSheetBottomView.allStudents;
        if (_allStudentsExpandedByGrade.isEmpty) {
          final grouped = _groupStudentsByGradeForSideSheet(
            DataManager.instance.students,
          );
          if (grouped.isNotEmpty) {
            _allStudentsExpandedByGrade[grouped.keys.first] = true;
          }
        }
      } else {
        _sideSheetBottomView = _SideSheetBottomView.waiting;
      }
    });
  }

  void _toggleFavoriteTemplatesSideSheetView() {
    setState(() {
      if (_sideSheetBottomView == _SideSheetBottomView.favoriteTemplates) {
        _sideSheetBottomView = _SideSheetBottomView.waiting;
      } else {
        _sideSheetBottomView = _SideSheetBottomView.favoriteTemplates;
      }
    });
  }

  void _toggleAllStudentsGrade(String key) {
    final nextExpanded = !(_allStudentsExpandedByGrade[key] ?? false);
    setState(() {
      _allStudentsExpandedByGrade.clear();
      if (nextExpanded) {
        _allStudentsExpandedByGrade[key] = true;
      }
    });
    if (!nextExpanded) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final targetContext = _allStudentsGradeAnchorKeys[key]?.currentContext;
      if (targetContext == null) return;
      Scrollable.ensureVisible(
        targetContext,
        alignment: 0.0,
        alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Widget _buildAllStudentsBottomPanel({required double containerWidth}) {
    final scale = ((containerWidth / 420.0).clamp(0.78, 1.0));
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24.0, 0.0, 24.0, 12.0),
        child: ValueListenableBuilder<List<StudentWithInfo>>(
          valueListenable: DataManager.instance.studentsNotifier,
          builder: (context, students, _) {
            final grouped = _groupStudentsByGradeForSideSheet(students);
            if (grouped.isEmpty) {
              return const Center(
                child: Text(
                  '등록된 학생이 없습니다.',
                  style: TextStyle(
                    color: Color(0xFF9FB3B3),
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              );
            }
            final gradeEntries = grouped.entries.toList();

            return Scrollbar(
              controller: _waitingScrollCtrl,
              thumbVisibility: true,
              child: ListView(
                controller: _waitingScrollCtrl,
                padding: EdgeInsets.zero,
                children: [
                  for (int i = 0; i < gradeEntries.length; i++) ...[
                    _buildAllStudentsGradeTile(
                      gradeEntries[i].key,
                      gradeEntries[i].value,
                      scale: scale,
                    ),
                    if (i != gradeEntries.length - 1)
                      const Divider(
                        height: 1,
                        thickness: 1,
                        color: Color(0xFF223131),
                      ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildFavoriteTemplatesBottomPanel({required double containerWidth}) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 14),
        child: FavoriteTemplatesPanel(
          containerWidth: containerWidth,
        ),
      ),
    );
  }

  Widget _buildAllStudentsGradeTile(
    String gradeKey,
    List<StudentWithInfo> students, {
    required double scale,
  }) {
    final isExpanded = _allStudentsExpandedByGrade[gradeKey] ?? false;
    final String levelName = students.isEmpty
        ? gradeKey
        : _educationLevelToKorean(students.first.student.educationLevel);
    final int grade = students.isEmpty ? 0 : students.first.student.grade;
    final String gradeLabel = grade > 0 ? '$levelName $grade학년' : levelName;
    return Padding(
      key: _allStudentsGradeAnchorKeys.putIfAbsent(gradeKey, () => GlobalKey()),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        children: [
          InkWell(
            onTap: () => _toggleAllStudentsGrade(gradeKey),
            child: SizedBox(
              height: _allStudentsListRowHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    Text(
                      gradeLabel,
                      style: const TextStyle(
                        color: Color(0xFFEAF2F2),
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${students.length}명',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 14 * scale,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      isExpanded ? Icons.expand_less : Icons.expand_more,
                      color: Colors.white70,
                      size: 20,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (isExpanded) ...[
            const Divider(height: 1, thickness: 1, color: Color(0xFF223131)),
            const SizedBox(height: 6),
            for (int i = 0; i < students.length; i++) ...[
              _buildAllStudentsStudentRow(students[i], scale: scale),
            ],
            const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }

  Widget _buildAllStudentsStudentRow(
    StudentWithInfo info, {
    required double scale,
  }) {
    final schoolText = info.student.school.trim().isEmpty
        ? '학교 정보 없음'
        : info.student.school.trim();
    final String initial = info.student.name.characters.take(1).toString();
    final row = SizedBox(
      height: _allStudentsListRowHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            CircleAvatar(
              radius: 15,
              backgroundColor:
                  info.student.groupInfo?.color ?? const Color(0xFF2C3A3A),
              child: Text(
                initial,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: info.student.name,
                      style: const TextStyle(
                        color: Color(0xFFEAF2F2),
                        fontSize: 19,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    TextSpan(
                      text: '  $schoolText',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 13 * scale,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 10),
            Tooltip(
              message: '학생정보 상세내역',
              child: IconButton(
                onPressed: () => unawaited(_openStudentProfile(info)),
                icon: const Icon(
                  Icons.badge_outlined,
                  size: 22,
                  color: Colors.white70,
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 42, minHeight: 42),
                splashRadius: 22,
                visualDensity: VisualDensity.standard,
              ),
            ),
            const SizedBox(width: 10),
            Tooltip(
              message: '시간 기록',
              child: IconButton(
                onPressed: () =>
                    unawaited(StudentTimeInfoDialog.show(context, info)),
                icon: const Icon(
                  Icons.schedule_outlined,
                  size: 22,
                  color: Colors.white70,
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 42, minHeight: 42),
                splashRadius: 22,
                visualDensity: VisualDensity.standard,
              ),
            ),
          ],
        ),
      ),
    );
    return _wrapTextbookDropTargetForStudent(
      studentId: info.student.id,
      child: row,
    );
  }

  @override
  void initState() {
    super.initState();
    // 과제 데이터 DB에서 1회 로드
    HomeworkStore.instance.loadAll();
    hideGlobalMemoFloatingBanners.value =
        (_selectedIndex == 0 || _selectedIndex == 1);
    blockRightSideSheetOpen.value = false;
    // 출석 데이터 변경 시 사이드 시트 캐시 무효화
    DataManager.instance.attendanceRecordsNotifier.addListener(
      _markSideSheetDirty,
    );
    _rotationAnimation = AnimationController(
      duration: const Duration(milliseconds: 240),
      vsync: this,
    );
    // 진단 로그 제거됨
    _sideSheetAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _rotationAnimation, curve: Curves.easeInOutCubic),
    );
    _fabController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _fabScaleAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _fabController, curve: Curves.easeOut));
    _fabOpacityAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _fabController, curve: Curves.easeInOut));
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

    final todayAttendanceRecords = DataManager.instance.attendanceRecords.where(
      (record) {
        final recordDate = DateTime(
          record.classDateTime.year,
          record.classDateTime.month,
          record.classDateTime.day,
        );
        return recordDate.isAfter(
              todayStart.subtract(const Duration(days: 1)),
            ) &&
            recordDate.isBefore(todayEnd) &&
            record.isPresent;
      },
    ).toList();

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
          a.year == b.year &&
          a.month == b.month &&
          a.day == b.day &&
          a.hour == b.hour &&
          a.minute == b.minute;
      for (final ov in DataManager.instance.sessionOverrides) {
        if (ov.studentId != record.studentId) continue;
        if (ov.reason != OverrideReason.makeup) continue; // 보강만 대상
        if (!(ov.overrideType == OverrideType.add ||
            ov.overrideType == OverrideType.replace)) continue;
        if (ov.status == OverrideStatus.canceled)
          continue; // 취소 제외 (planned/completed 모두 복원)
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
    // OverlayEntry가 남아있는 상태로 dispose되면 화면에 "유령 툴팁"이 남을 수 있으므로 강제 제거
    _removeTooltip();
    _classTagBarrierTimer?.cancel();
    _attendedTapTimer?.cancel();
    _classTagBarrierActive.dispose();
    DataManager.instance.attendanceRecordsNotifier.removeListener(
      _markSideSheetDirty,
    );
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
      // 시트 닫힘/애니메이션 중에는 MouseRegion.onExit가 보장되지 않을 수 있어 툴팁을 강제 제거
      _removeTooltip();
      _rotationAnimation.reverse();
    } else {
      _sideSheetAnchorDate = _dateOnly(DateTime.now());
      _sideSheetDataDirty = true;
      // ✅ 사이드 시트가 planned 누락으로 비어 보이지 않도록
      // 오늘 기준 2주(15일) 커버리지를 보장한다.
      if (_sideSheetDebug) {
        debugPrint(
          '[SIDE][toggle] open -> ensureCoverage(days=15) recordsLen=${DataManager.instance.attendanceRecords.length}',
        );
      }
      unawaited(DataManager.instance.ensurePlannedCoverageForToday(days: 15));
      // 시범 수업(문의 노트) 슬롯도 사이드 시트에서 사용할 수 있도록 lazy-load
      unawaited(ConsultTrialLessonService.instance.load());
      _rotationAnimation.forward();
    }
  }

  Future<void> _restoreLeavedStudentToAttended(_LeavedDialogEntry entry) async {
    final target = entry.target;
    final classDateTime = target.classDateTime;
    final existing = DataManager.instance.getAttendanceRecord(
      target.student.id,
      classDateTime,
    );
    final resolvedArrival = existing?.arrivalTime ??
        entry.arrival ??
        _attendTimes[target.setId] ??
        DateTime.now();

    if (existing != null && existing.id != null) {
      final updated = AttendanceRecord(
        id: existing.id,
        studentId: existing.studentId,
        occurrenceId: existing.occurrenceId,
        classDateTime: existing.classDateTime,
        classEndTime: existing.classEndTime,
        className: existing.className,
        isPresent: true,
        arrivalTime: resolvedArrival,
        departureTime: null,
        notes: existing.notes,
        sessionTypeId: existing.sessionTypeId,
        setId: existing.setId ?? target.setId,
        snapshotId: existing.snapshotId,
        batchSessionId: existing.batchSessionId,
        cycle: existing.cycle,
        sessionOrder: existing.sessionOrder,
        isPlanned: existing.isPlanned,
        createdAt: existing.createdAt,
        updatedAt: DateTime.now(),
        version: existing.version,
      );
      await DataManager.instance.updateAttendanceRecord(updated);
    } else {
      await DataManager.instance.saveOrUpdateAttendance(
        studentId: target.student.id,
        classDateTime: classDateTime,
        classEndTime: classDateTime.add(target.duration),
        className: target.classInfo?.name ?? '수업',
        isPresent: true,
        arrivalTime: resolvedArrival,
        departureTime: null,
        setId: target.setId,
        sessionTypeId: target.classInfo?.id,
      );
    }

    if (!mounted) return;
    setState(() {
      _leavedSetIds.remove(target.setId);
      _leaveTimes.remove(target.setId);
      _attendedSetIds.add(target.setId);
      _attendTimes[target.setId] = resolvedArrival;
      _sideSheetDataDirty = true;
    });
  }

  Future<DateTime?> _pickAttendanceTimeForDate({
    required BuildContext context,
    required DateTime date,
    required DateTime initial,
    required String helpText,
  }) async {
    final picked = await showTimePicker(
      context: context,
      helpText: helpText,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (picked == null) return null;
    return DateTime(
      date.year,
      date.month,
      date.day,
      picked.hour,
      picked.minute,
    );
  }

  Future<_LeavedDialogEntry?> _editLeavedDialogEntryTime({
    required BuildContext context,
    required _LeavedDialogEntry entry,
    required bool isArrival,
  }) async {
    final target = entry.target;
    final rec = DataManager.instance.getAttendanceRecord(
      target.student.id,
      target.classDateTime,
    );
    if (rec == null || rec.id == null) {
      if (mounted) {
        _showFloatingSnackBar(this.context, '출석 기록을 찾지 못했어요.');
      }
      return null;
    }

    final baseDate = target.classDateTime;
    final currentArrival = entry.arrival ?? rec.arrivalTime;
    final currentDeparture = entry.departure ?? rec.departureTime;
    final fallbackInitial = target.classDateTime;
    final initial = isArrival
        ? (currentArrival ?? fallbackInitial)
        : (currentDeparture ??
            currentArrival ??
            fallbackInitial.add(target.duration));
    final picked = await _pickAttendanceTimeForDate(
      context: context,
      date: baseDate,
      initial: initial,
      helpText: isArrival ? '등원 시간 수정' : '하원 시간 수정',
    );
    if (picked == null) return null;

    final nextArrival = isArrival ? picked : currentArrival;
    final nextDeparture = isArrival ? currentDeparture : picked;

    if (nextArrival != null &&
        nextDeparture != null &&
        nextDeparture.isBefore(nextArrival)) {
      if (mounted) {
        _showFloatingSnackBar(this.context, '하원 시간은 등원 시간보다 이를 수 없어요.');
      }
      return null;
    }

    final updated = rec.copyWith(
      isPresent: true,
      arrivalTime: nextArrival,
      departureTime: nextDeparture,
      updatedAt: DateTime.now(),
    );

    try {
      await DataManager.instance.updateAttendanceRecord(updated);
    } on StateError catch (e) {
      if (mounted) {
        final msg = e.message == 'CONFLICT_ATTENDANCE_VERSION'
            ? '다른 기기에서 먼저 수정되었습니다. 잠시 후 다시 시도해 주세요.'
            : '시간 수정에 실패했습니다. 다시 시도해 주세요.';
        _showFloatingSnackBar(this.context, msg);
      }
      return null;
    } catch (_) {
      if (mounted) {
        _showFloatingSnackBar(this.context, '시간 수정에 실패했습니다. 다시 시도해 주세요.');
      }
      return null;
    }

    if (!mounted) return null;
    setState(() {
      if (nextArrival != null) {
        _attendedSetIds.add(target.setId);
        _attendTimes[target.setId] = nextArrival;
      }
      if (nextDeparture != null) {
        _leavedSetIds.add(target.setId);
        _leaveTimes[target.setId] = nextDeparture;
      } else {
        _leavedSetIds.remove(target.setId);
        _leaveTimes.remove(target.setId);
      }
      _sideSheetDataDirty = true;
    });
    _showFloatingSnackBar(
      this.context,
      isArrival ? '등원 시간이 수정되었어요.' : '하원 시간이 수정되었어요.',
    );
    return _LeavedDialogEntry(
      target: target,
      arrival: nextArrival,
      departure: nextDeparture,
    );
  }

  Future<void> _showLeavedStudentsDialog(
    List<_AttendanceTarget> leaved,
    Map<String, DateTime?> arrivalBySet,
    Map<String, DateTime?> departureBySet,
  ) async {
    final entries = leaved
        .map(
          (target) => _LeavedDialogEntry(
            target: target,
            arrival: arrivalBySet[target.setId],
            departure: departureBySet[target.setId],
          ),
        )
        .toList()
      ..sort((a, b) {
        final DateTime aKey =
            a.departure ?? a.arrival ?? DateTime.fromMillisecondsSinceEpoch(0);
        final DateTime bKey =
            b.departure ?? b.arrival ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bKey.compareTo(aKey);
      });

    final double listHeight = entries.isEmpty
        ? 140.0
        : math.min(420.0, math.max(220.0, entries.length * 76.0));

    await showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.55),
      builder: (dialogContext) {
        final dialogEntries = List<_LeavedDialogEntry>.from(entries);
        final Set<String> cancellingSetIds = <String>{};
        final Set<String> editingTimeKeys = <String>{};

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
                    icon: const Icon(
                      Icons.arrow_back,
                      color: Colors.white70,
                      size: 20,
                    ),
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

        Widget buildTimeBadge({
          required String label,
          required String value,
          required VoidCallback? onTap,
          bool isBusy = false,
        }) {
          final badge = Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF1B6B63).withOpacity(0.18),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$label $value',
                  style: const TextStyle(
                    color: Color(0xFFEAF2F2),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 6),
                isBusy
                    ? const SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(strokeWidth: 1.8),
                      )
                    : const Icon(
                        Icons.edit_outlined,
                        size: 13,
                        color: Color(0xFFB6C9C9),
                      ),
              ],
            ),
          );
          if (onTap == null || isBusy) return badge;
          return Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: onTap,
              child: badge,
            ),
          );
        }

        return Dialog(
          backgroundColor: const Color(0xFF0B1112),
          insetPadding: const EdgeInsets.all(24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(26, 26, 26, 22),
              decoration: BoxDecoration(
                color: const Color(0xFF0B1112),
                borderRadius: BorderRadius.circular(12),
              ),
              child: StatefulBuilder(
                builder: (context, setDialogState) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      buildHeader(),
                      const SizedBox(height: 14),
                      SizedBox(
                        height: listHeight,
                        child: dialogEntries.isEmpty
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
                                  itemCount: dialogEntries.length,
                                  separatorBuilder: (_, __) =>
                                      const SizedBox(height: 12),
                                  itemBuilder: (context, index) {
                                    final entry = dialogEntries[index];
                                    final setId = entry.target.setId;
                                    final bool isCancelling =
                                        cancellingSetIds.contains(setId);
                                    final String arrivalEditKey =
                                        '$setId:arrival';
                                    final String departureEditKey =
                                        '$setId:departure';
                                    final bool isEditingArrival =
                                        editingTimeKeys.contains(
                                      arrivalEditKey,
                                    );
                                    final bool isEditingDeparture =
                                        editingTimeKeys.contains(
                                      departureEditKey,
                                    );
                                    final arrivalText = entry.arrival != null
                                        ? _formatTime(entry.arrival!)
                                        : '--:--';
                                    final departureText =
                                        entry.departure != null
                                            ? _formatTime(entry.departure!)
                                            : '--:--';
                                    return Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical: 14,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF10171A),
                                        borderRadius: BorderRadius.circular(16),
                                        border: Border.all(
                                          color: const Color(
                                            0xFF1B6B63,
                                          ).withOpacity(0.25),
                                        ),
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      entry.target.student.name,
                                                      style: const TextStyle(
                                                        color: Color(
                                                          0xFFEAF2F2,
                                                        ),
                                                        fontSize: 17,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                      ),
                                                    ),
                                                    if (entry
                                                            .target.classInfo !=
                                                        null) ...[
                                                      const SizedBox(height: 4),
                                                      Text(
                                                        entry.target.classInfo!
                                                            .name,
                                                        style: const TextStyle(
                                                          color: Color(
                                                            0xFF7F8A8E,
                                                          ),
                                                          fontSize: 13,
                                                        ),
                                                      ),
                                                    ],
                                                  ],
                                                ),
                                              ),
                                              const SizedBox(width: 10),
                                              TextButton.icon(
                                                onPressed: isCancelling
                                                    ? null
                                                    : () async {
                                                        setDialogState(() {
                                                          cancellingSetIds.add(
                                                            setId,
                                                          );
                                                        });
                                                        try {
                                                          await _restoreLeavedStudentToAttended(
                                                            entry,
                                                          );
                                                          if (dialogContext
                                                              .mounted) {
                                                            setDialogState(() {
                                                              dialogEntries
                                                                  .removeWhere(
                                                                (e) =>
                                                                    e.target.setId ==
                                                                        setId &&
                                                                    e.target.student
                                                                            .id ==
                                                                        entry
                                                                            .target
                                                                            .student
                                                                            .id,
                                                              );
                                                            });
                                                          }
                                                          if (mounted) {
                                                            _showFloatingSnackBar(
                                                              this.context,
                                                              '하원 취소 완료: 등원중으로 복구했어요.',
                                                            );
                                                          }
                                                        } on StateError catch (e) {
                                                          if (mounted) {
                                                            final msg = e
                                                                        .message ==
                                                                    'CONFLICT_ATTENDANCE_VERSION'
                                                                ? '다른 기기에서 먼저 수정되었습니다. 잠시 후 다시 시도해 주세요.'
                                                                : '하원 취소에 실패했습니다. 다시 시도해 주세요.';
                                                            _showFloatingSnackBar(
                                                              this.context,
                                                              msg,
                                                            );
                                                          }
                                                        } catch (_) {
                                                          if (mounted) {
                                                            _showFloatingSnackBar(
                                                              this.context,
                                                              '하원 취소에 실패했습니다. 다시 시도해 주세요.',
                                                            );
                                                          }
                                                        } finally {
                                                          if (dialogContext
                                                              .mounted) {
                                                            setDialogState(() {
                                                              cancellingSetIds
                                                                  .remove(
                                                                setId,
                                                              );
                                                            });
                                                          }
                                                        }
                                                      },
                                                icon: isCancelling
                                                    ? const SizedBox(
                                                        width: 14,
                                                        height: 14,
                                                        child:
                                                            CircularProgressIndicator(
                                                          strokeWidth: 2.0,
                                                        ),
                                                      )
                                                    : const Icon(
                                                        Icons.undo_rounded,
                                                        size: 17,
                                                      ),
                                                label: Text(
                                                  isCancelling
                                                      ? '복구 중...'
                                                      : '하원 취소',
                                                ),
                                                style: TextButton.styleFrom(
                                                  foregroundColor: const Color(
                                                    0xFFEAF2F2,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 10),
                                          Wrap(
                                            spacing: 8,
                                            runSpacing: 8,
                                            children: [
                                              buildTimeBadge(
                                                label: '등원',
                                                value: arrivalText,
                                                isBusy: isEditingArrival,
                                                onTap: (isCancelling ||
                                                        isEditingDeparture)
                                                    ? null
                                                    : () async {
                                                        setDialogState(() {
                                                          editingTimeKeys.add(
                                                            arrivalEditKey,
                                                          );
                                                        });
                                                        try {
                                                          final updatedEntry =
                                                              await _editLeavedDialogEntryTime(
                                                            context:
                                                                dialogContext,
                                                            entry: entry,
                                                            isArrival: true,
                                                          );
                                                          if (updatedEntry !=
                                                                  null &&
                                                              dialogContext
                                                                  .mounted) {
                                                            final idx =
                                                                dialogEntries
                                                                    .indexWhere(
                                                              (e) =>
                                                                  e.target.setId ==
                                                                      setId &&
                                                                  e.target.student
                                                                          .id ==
                                                                      entry
                                                                          .target
                                                                          .student
                                                                          .id,
                                                            );
                                                            if (idx != -1) {
                                                              setDialogState(
                                                                  () {
                                                                dialogEntries[
                                                                        idx] =
                                                                    updatedEntry;
                                                              });
                                                            }
                                                          }
                                                        } finally {
                                                          if (dialogContext
                                                              .mounted) {
                                                            setDialogState(() {
                                                              editingTimeKeys
                                                                  .remove(
                                                                arrivalEditKey,
                                                              );
                                                            });
                                                          }
                                                        }
                                                      },
                                              ),
                                              buildTimeBadge(
                                                label: '하원',
                                                value: departureText,
                                                isBusy: isEditingDeparture,
                                                onTap: (isCancelling ||
                                                        isEditingArrival)
                                                    ? null
                                                    : () async {
                                                        setDialogState(() {
                                                          editingTimeKeys.add(
                                                            departureEditKey,
                                                          );
                                                        });
                                                        try {
                                                          final updatedEntry =
                                                              await _editLeavedDialogEntryTime(
                                                            context:
                                                                dialogContext,
                                                            entry: entry,
                                                            isArrival: false,
                                                          );
                                                          if (updatedEntry !=
                                                                  null &&
                                                              dialogContext
                                                                  .mounted) {
                                                            final idx =
                                                                dialogEntries
                                                                    .indexWhere(
                                                              (e) =>
                                                                  e.target.setId ==
                                                                      setId &&
                                                                  e.target.student
                                                                          .id ==
                                                                      entry
                                                                          .target
                                                                          .student
                                                                          .id,
                                                            );
                                                            if (idx != -1) {
                                                              setDialogState(
                                                                  () {
                                                                dialogEntries[
                                                                        idx] =
                                                                    updatedEntry;
                                                              });
                                                            }
                                                          }
                                                        } finally {
                                                          if (dialogContext
                                                              .mounted) {
                                                            setDialogState(() {
                                                              editingTimeKeys
                                                                  .remove(
                                                                departureEditKey,
                                                              );
                                                            });
                                                          }
                                                        }
                                                      },
                                              ),
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
                  );
                },
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
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: const SizedBox(width: 770, height: 760, child: MakeupView()),
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
    final int _railSelectedIndex =
        (_selectedIndex >= 0 && _selectedIndex <= 5) ? _selectedIndex : 0;
    return Scaffold(
      body: Row(
        children: [
          CustomNavigationRail(
            selectedIndex: _railSelectedIndex,
            onDestinationSelected: (int index) {
              setState(() {
                _selectedIndex = index;
              });
              hideGlobalMemoFloatingBanners.value = (index == 0 || index == 1);
              if (index != 1) {
                blockRightSideSheetOpen.value = false;
              }
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

              final bool isComplete =
                  _rotationAnimation.status == AnimationStatus.completed &&
                      progress >= 1.0;
              if (isComplete != _sideSheetWasComplete) {
                _sideSheetWasComplete = isComplete;
              }
              // 카드 리스트를 한 줄로 묶어서 ... 처리할 수 있도록 helper
              Widget _ellipsisWrap(
                List<Widget> cards, {
                int maxLines = 2,
                double spacing = 8,
                double runSpacing = 8,
              }) {
                // 한 줄에 최대 3개 카드만 보이게 제한 (예시)
                const int maxPerLine = 3;
                List<Widget> lines = [];
                int i = 0;
                while (i < cards.length && lines.length < maxLines) {
                  int end = (i + maxPerLine < cards.length)
                      ? i + maxPerLine
                      : cards.length;
                  lines.add(
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: cards.sublist(i, end),
                    ),
                  );
                  i = end;
                }
                if (i < cards.length) {
                  lines.add(
                    const Text(
                      '...',
                      style: TextStyle(color: Colors.white54, fontSize: 18),
                    ),
                  );
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
              final containerWidth = progress == 0
                  ? 0.0
                  : (maxWidth * progress).clamp(0.0, maxWidth);
              _sideSheetWidth = containerWidth;

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
                return _wrapSideSheetDragHoverTarget(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeInOut,
                    width: containerWidth,
                    key: _sideSheetKey,
                    color: const Color(0xFF0B1112),
                  ),
                );
              }

              return _wrapSideSheetDragHoverTarget(
                child: ValueListenableBuilder<List<AttendanceRecord>>(
                  valueListenable:
                      DataManager.instance.attendanceRecordsNotifier,
                  builder: (context, _records, _) {
                    if (_sideSheetDataDirty) {
                      if (_sideSheetDebug) {
                        debugPrint(
                          '[SIDE][recompute-start] recordsLen=${_records.length}',
                        );
                      }
                      _recomputeSideSheetCache(_records);
                      if (_sideSheetDebug) {
                        debugPrint(
                          '[SIDE][recompute] waiting=${_cachedWaiting.length}, attended=${_cachedAttended.length}, leaved=${_cachedLeaved.length}',
                        );
                      }
                    }
                    final attended = _cachedAttended;
                    final leaved = _cachedLeaved;
                    final arrivalBySet = _arrivalBySetCache;
                    final departureBySet = _departureBySetCache;
                    final waitingByTime = _waitingByTimeCache;

                    return ValueListenableBuilder<List<ConsultTrialLessonSlot>>(
                      valueListenable:
                          ConsultTrialLessonService.instance.slotsNotifier,
                      builder: (context, trialSlots, _) {
                        final targetDate = _dateOnly(_sideSheetAnchorDate);

                        final trialToday = trialSlots.where((s) {
                          final wk = _dateOnly(s.weekStart);
                          final slotDate = _dateOnly(
                            wk.add(Duration(days: s.dayIndex)),
                          );
                          return slotDate == targetDate;
                        }).toList();

                        final trialAttended = trialToday
                            .where(
                              (s) =>
                                  s.arrivalTime != null &&
                                  s.departureTime == null,
                            )
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

                        final trialWaitingByTime = SplayTreeMap<DateTime,
                            List<ConsultTrialLessonSlot>>();
                        for (final s in trialWaiting) {
                          final k = DateTime(
                            targetDate.year,
                            targetDate.month,
                            targetDate.day,
                            s.hour,
                            s.minute,
                          );
                          (trialWaitingByTime[k] ??= <ConsultTrialLessonSlot>[])
                              .add(s);
                        }

                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          curve: Curves.easeInOut,
                          width: containerWidth,
                          key: _sideSheetKey,
                          color: const Color(0xFF0B1112),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              Column(
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      24,
                                      8,
                                      24,
                                      12,
                                    ),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Row(
                                          children: [
                                            _SideSheetDateHeader(
                                              date: _sideSheetAnchorDate,
                                              onMoveToYesterday:
                                                  _moveSideSheetToYesterday,
                                              onMoveToToday:
                                                  _moveSideSheetToToday,
                                            ),
                                            const Spacer(),
                                          ],
                                        ),
                                        const SizedBox(height: 14),
                                        Align(
                                          alignment: Alignment.center,
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Tooltip(
                                                message: _sideSheetBottomView ==
                                                        _SideSheetBottomView
                                                            .allStudents
                                                    ? '출석 페이지 보기'
                                                    : '모든 학생 리스트 보기',
                                                child: IconButton(
                                                  icon: Icon(
                                                    _sideSheetBottomView ==
                                                            _SideSheetBottomView
                                                                .allStudents
                                                        ? Icons.groups
                                                        : Icons.groups_outlined,
                                                    color: _sideSheetBottomView ==
                                                            _SideSheetBottomView
                                                                .allStudents
                                                        ? const Color(
                                                            0xFF33A373,
                                                          )
                                                        : Colors.white70,
                                                    size: 22,
                                                  ),
                                                  padding: EdgeInsets.zero,
                                                  constraints:
                                                      const BoxConstraints(
                                                    minWidth: 44,
                                                    minHeight: 44,
                                                  ),
                                                  onPressed:
                                                      _toggleSideSheetBottomView,
                                                ),
                                              ),
                                              const SizedBox(width: 10),
                                              Tooltip(
                                                message: '보강 관리',
                                                child: IconButton(
                                                  icon: const Icon(
                                                    Icons.event_repeat,
                                                    color: Colors.white70,
                                                    size: 22,
                                                  ),
                                                  padding: EdgeInsets.zero,
                                                  constraints:
                                                      const BoxConstraints(
                                                    minWidth: 44,
                                                    minHeight: 44,
                                                  ),
                                                  onPressed:
                                                      _showMakeupManagementDialog,
                                                ),
                                              ),
                                              const SizedBox(width: 10),
                                              Tooltip(
                                                message: '수업 타임라인',
                                                child: IconButton(
                                                  icon: const Icon(
                                                    Icons.timeline,
                                                    color: Colors.white70,
                                                    size: 22,
                                                  ),
                                                  padding: EdgeInsets.zero,
                                                  constraints:
                                                      const BoxConstraints(
                                                    minWidth: 44,
                                                    minHeight: 44,
                                                  ),
                                                  onPressed: () async {
                                                    await showDialog(
                                                      context: context,
                                                      builder: (_) =>
                                                          const ClassContentEventsDialog(),
                                                    );
                                                  },
                                                ),
                                              ),
                                              const SizedBox(width: 6),
                                              Tooltip(
                                                message: '하원 리스트',
                                                child: IconButton(
                                                  icon: const Icon(
                                                    Icons.featured_play_list,
                                                    color: Colors.white70,
                                                    size: 22,
                                                  ),
                                                  padding: EdgeInsets.zero,
                                                  constraints:
                                                      const BoxConstraints(
                                                    minWidth: 44,
                                                    minHeight: 44,
                                                  ),
                                                  onPressed: () async {
                                                    await _showLeavedStudentsDialog(
                                                      leaved,
                                                      arrivalBySet,
                                                      departureBySet,
                                                    );
                                                  },
                                                ),
                                              ),
                                              const SizedBox(width: 10),
                                              Tooltip(
                                                message: _sideSheetBottomView ==
                                                        _SideSheetBottomView
                                                            .favoriteTemplates
                                                    ? '즐겨찾기 닫기'
                                                    : '즐겨찾기',
                                                child: IconButton(
                                                  icon: Icon(
                                                    Icons.star_rounded,
                                                    color: _sideSheetBottomView ==
                                                            _SideSheetBottomView
                                                                .favoriteTemplates
                                                        ? const Color(
                                                            0xFF33A373)
                                                        : Colors.white70,
                                                    size: 22,
                                                  ),
                                                  padding: EdgeInsets.zero,
                                                  constraints:
                                                      const BoxConstraints(
                                                    minWidth: 44,
                                                    minHeight: 44,
                                                  ),
                                                  onPressed:
                                                      _toggleFavoriteTemplatesSideSheetView,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: 24.0,
                                    ),
                                    child: Divider(
                                      height: 1,
                                      thickness: 1,
                                      color: Color(0xFF223131),
                                    ),
                                  ),
                                  if (_sideSheetBottomView ==
                                      _SideSheetBottomView.waiting) ...[
                                    // 출석 박스
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 24.0,
                                      ),
                                      child: Container(
                                        // 헤더(날짜+버튼)와의 간격을 절반으로 축소
                                        margin: const EdgeInsets.only(
                                          top: 0,
                                          bottom: 0,
                                        ),
                                        width: double.infinity,
                                        constraints: BoxConstraints(
                                          minHeight: _cardActualHeight *
                                              ((containerWidth / 420.0).clamp(
                                                0.78,
                                                1.0,
                                              )),
                                          maxHeight: _cardActualHeight *
                                                  ((containerWidth / 420.0)
                                                      .clamp(0.78, 1.0)) *
                                                  _attendedMaxLines +
                                              _attendedRunSpacing *
                                                  ((containerWidth / 420.0)
                                                      .clamp(0.78, 1.0)) *
                                                  (_attendedMaxLines - 1),
                                        ),
                                        // 내부 여백: 왼쪽/상단은 0으로(요청), 나머지는 유지
                                        padding: const EdgeInsets.fromLTRB(
                                          0,
                                          22.0,
                                          16.0,
                                          24.0,
                                        ),
                                        child: Scrollbar(
                                          controller: _attendedScrollCtrl,
                                          thumbVisibility: true,
                                          child: SingleChildScrollView(
                                            controller: _attendedScrollCtrl,
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                if (attended.isEmpty &&
                                                    trialAttended.isEmpty)
                                                  const Center(
                                                    child: Padding(
                                                      padding: EdgeInsets.only(
                                                        left: 14.0,
                                                      ),
                                                      child: Text(
                                                        '출석',
                                                        style: TextStyle(
                                                          color: Color(
                                                            0xFF9FB3B3,
                                                          ),
                                                          fontSize: 22,
                                                          fontWeight:
                                                              FontWeight.bold,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                if (attended.isNotEmpty)
                                                  Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      for (int i = 0;
                                                          i < attended.length;
                                                          i++) ...[
                                                        _buildAttendanceCard(
                                                          attended[i],
                                                          status: 'attended',
                                                          key: ValueKey(
                                                            'attended_${attended[i].setId}',
                                                          ),
                                                          scale:
                                                              ((containerWidth /
                                                                      420.0)
                                                                  .clamp(
                                                            0.78,
                                                            1.0,
                                                          )),
                                                          arrival: arrivalBySet[
                                                              attended[i]
                                                                  .setId],
                                                          departure:
                                                              departureBySet[
                                                                  attended[i]
                                                                      .setId],
                                                        ),
                                                        if (i !=
                                                            attended.length - 1)
                                                          SizedBox(
                                                            height: 8 *
                                                                ((containerWidth /
                                                                        420.0)
                                                                    .clamp(
                                                                  0.78,
                                                                  1.0,
                                                                )),
                                                          ),
                                                      ],
                                                    ],
                                                  ),
                                                if (trialAttended
                                                    .isNotEmpty) ...[
                                                  if (attended.isNotEmpty)
                                                    const SizedBox(height: 8),
                                                  for (int i = 0;
                                                      i < trialAttended.length;
                                                      i++) ...[
                                                    _buildTrialLessonAttendanceCard(
                                                      trialAttended[i],
                                                      status: 'attended',
                                                      key: ValueKey(
                                                        'trial_attended_${trialAttended[i].id}',
                                                      ),
                                                      scale: ((containerWidth /
                                                              420.0)
                                                          .clamp(
                                                        0.78,
                                                        1.0,
                                                      )),
                                                    ),
                                                    if (i !=
                                                        trialAttended.length -
                                                            1)
                                                      SizedBox(
                                                        height: 8 *
                                                            ((containerWidth /
                                                                    420.0)
                                                                .clamp(
                                                              0.78,
                                                              1.0,
                                                            )),
                                                      ),
                                                  ],
                                                ],
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    // 출석(등원한) 영역과 등원 예정 영역 구분선
                                    const Padding(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: 24.0,
                                      ),
                                      child: Divider(
                                        height: 1,
                                        thickness: 1,
                                        color: Color(0xFF223131),
                                      ),
                                    ),
                                    // 출석 전 학생 리스트
                                    if (waitingByTime.isNotEmpty ||
                                        trialWaitingByTime.isNotEmpty)
                                      Expanded(
                                        child: Padding(
                                          padding: const EdgeInsets.only(
                                            top: 8,
                                            left: 24.0,
                                            right: 24.0,
                                            bottom: 24.0,
                                          ),
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
                                                  ..sort(
                                                    (a, b) => a.compareTo(b),
                                                  ))) ...[
                                                  Padding(
                                                    padding:
                                                        const EdgeInsets.only(
                                                      bottom: 4.0,
                                                    ),
                                                    child: Center(
                                                      child: Text(
                                                        _formatTime(t),
                                                        style: const TextStyle(
                                                          color: Colors.white54,
                                                          fontSize: 14,
                                                          fontWeight:
                                                              FontWeight.bold,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                  Center(
                                                    child: Wrap(
                                                      alignment:
                                                          WrapAlignment.center,
                                                      spacing: _cardSpacing *
                                                          ((containerWidth /
                                                                  420.0)
                                                              .clamp(
                                                            0.78,
                                                            1.0,
                                                          )),
                                                      runSpacing: _cardSpacing *
                                                          ((containerWidth /
                                                                  420.0)
                                                              .clamp(
                                                            0.78,
                                                            1.0,
                                                          )),
                                                      children: [
                                                        for (final w
                                                            in (waitingByTime[
                                                                    t] ??
                                                                const <_AttendanceTarget>[]))
                                                          _buildAttendanceCard(
                                                            w,
                                                            status: 'waiting',
                                                            key: ValueKey(
                                                              'waiting_${w.setId}',
                                                            ),
                                                            scale:
                                                                ((containerWidth /
                                                                        420.0)
                                                                    .clamp(
                                                              0.78,
                                                              1.0,
                                                            )),
                                                            arrival:
                                                                arrivalBySet[
                                                                    w.setId],
                                                            departure:
                                                                departureBySet[
                                                                    w.setId],
                                                          ),
                                                        for (final s
                                                            in (trialWaitingByTime[
                                                                    t] ??
                                                                const <ConsultTrialLessonSlot>[]))
                                                          _buildTrialLessonAttendanceCard(
                                                            s,
                                                            status: 'waiting',
                                                            key: ValueKey(
                                                              'trial_waiting_${s.id}',
                                                            ),
                                                            scale:
                                                                ((containerWidth /
                                                                        420.0)
                                                                    .clamp(
                                                              0.78,
                                                              1.0,
                                                            )),
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
                                  if (_sideSheetBottomView ==
                                      _SideSheetBottomView.allStudents)
                                    _buildAllStudentsBottomPanel(
                                      containerWidth: containerWidth,
                                    ),
                                  if (_sideSheetBottomView ==
                                      _SideSheetBottomView.favoriteTemplates)
                                    _buildFavoriteTemplatesBottomPanel(
                                      containerWidth: containerWidth,
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
                ),
              );
            },
          ),
          Container(width: 1, color: const Color(0xFF4A4A4A)),
          Expanded(child: _buildContent()),
        ],
      ),
      floatingActionButton: ValueListenableBuilder<bool>(
        valueListenable: gradingModeActive,
        builder: (context, gradingOn, _) {
          if (_selectedIndex == 0 && gradingOn) return const SizedBox.shrink();
          return MainFabAlternative();
        },
      ),
    );
  }

  void _showFloatingSnackBar(BuildContext context, String message) {
    _snackBarController = ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFF2A2A2A),
        behavior: SnackBarBehavior.fixed,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // 출석/하원 카드 위젯 (툴팁은 외부에서 처리)
  Widget _buildAttendanceCard(
    _AttendanceTarget t, {
    required String status,
    Key? key,
    double scale = 1.0,
    DateTime? arrival,
    DateTime? departure,
  }) {
    Color borderColor;
    Color textColor = Colors.white70;
    Widget nameWidget;
    // 밑줄 색상 결정 (보강=파란색, 추가수업=초록색)
    final Color? underlineColor = t.overrideType == OverrideType.replace
        ? const Color(0xFF1976D2)
        : (t.overrideType == OverrideType.add ? const Color(0xFF4CAF50) : null);
    final bool isSpecialOverride = t.overrideType == OverrideType.replace ||
        t.overrideType == OverrideType.add;
    switch (status) {
      case 'attended':
        borderColor = const Color(0xFF33A373);
        textColor = const Color(0xFFEAF2F2);
        final DateTime? attendTime = arrival ?? _attendTimes[t.setId];
        final String timeText =
            attendTime != null ? _formatTime(attendTime) : '--:--';
        nameWidget = Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: t.student.name,
                style: TextStyle(
                  color: textColor,
                  fontSize: 19,
                  fontWeight: FontWeight.w500,
                  decoration:
                      underlineColor != null ? TextDecoration.underline : null,
                  decorationColor: underlineColor,
                  decorationThickness: underlineColor != null ? 2 : null,
                ),
              ),
              TextSpan(
                text: '  $timeText',
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          overflow: TextOverflow.ellipsis,
        );
        break;
      case 'leaved':
        borderColor = t.classInfo?.color ?? Colors.grey.shade700;
        textColor = Colors.white70;
        nameWidget = MouseRegion(
          onEnter: (event) {
            final overlay =
                Overlay.of(context).context.findRenderObject() as RenderBox;
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
              fontSize: 19,
              fontWeight: FontWeight.w500,
              decoration:
                  underlineColor != null ? TextDecoration.underline : null,
              decorationColor: underlineColor,
              decorationThickness: underlineColor != null ? 2 : null,
            ),
          ),
        );
        break;
      default:
        // waiting(등원 예정)
        // - 기본: 테두리=회색(통일)
        // - 수업이 있으면: 이름 + 테두리 수업 색상
        // - 보강/추가수업: 테두리만 해당 색상(보강=파랑, 추가=초록)
        final Color? classColor = t.classInfo?.color;
        borderColor = isSpecialOverride
            ? (t.overrideType == OverrideType.replace
                ? const Color(0xFF1976D2)
                : const Color(0xFF4CAF50))
            : (classColor ?? Colors.grey);
        textColor = (!isSpecialOverride && classColor != null)
            ? classColor
            : Colors.white70;
        const double waitingNameSize = 16;
        nameWidget = Text(
          t.student.name,
          style: TextStyle(
            color: textColor,
            fontSize: waitingNameSize,
            fontWeight: FontWeight.w500,
            // waiting에서는 underline을 쓰지 않고(이질감/중복) 테두리/이름색 규칙으로만 표현한다.
          ),
        );
    }
    // 텍스트 자체의 underline을 사용하여 높이 증가 없이 이름 전체에 밑줄 적용
    final Widget attendedChild = nameWidget;
    final Widget cardChild = nameWidget; // 기본은 이름만 사용 (waiting/leaved)
    if (status == 'attended') {
      // 출석(파란 네모) 카드: 가로 스크롤로 과제칩 표시(줄바꿈 없음)
      return Row(
        key: key,
        mainAxisSize: MainAxisSize.max,
        children: [
          _wrapTextbookDropTargetForStudent(
            studentId: t.student.id,
            child: Dismissible(
              key: ValueKey('attended_swipe_${t.setId}'),
              direction: DismissDirection.startToEnd,
              confirmDismiss: (_) async {
                final now = DateTime.now();
                final hasHomeworkItems =
                    HomeworkStore.instance.items(t.student.id).isNotEmpty;
                final HomeworkAssignSelection? selection = hasHomeworkItems
                    ? await showHomeworkAssignDialog(
                        context,
                        t.student.id,
                        anchorTime: t.classDateTime,
                      )
                    : const HomeworkAssignSelection(itemIds: [], dueDate: null);
                if (selection == null) {
                  return false;
                }
                setState(() {
                  _leavedSetIds.add(t.setId);
                  _leaveTimes[t.setId] = now;
                  _sideSheetDataDirty = true;
                });
                try {
                  final classDateTime = t.classDateTime;
                  final existing = DataManager.instance.getAttendanceRecord(
                    t.student.id,
                    classDateTime,
                  );
                  final DateTime arrival2 =
                      existing?.arrivalTime ?? _attendTimes[t.setId] ?? now;
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
                  // 하원 시 숙제 선택 다이얼로그
                  if (selection.itemIds.isNotEmpty) {
                    final selectedItemIds = selection.itemIds
                        .map((e) => e.trim())
                        .where((e) => e.isNotEmpty)
                        .toSet()
                        .toList(growable: false);
                    HomeworkStore.instance.markItemsAsHomework(
                      t.student.id,
                      selectedItemIds,
                      dueDate: selection.dueDate,
                      cloneCompletedItems: true,
                    );
                  }
                  final selectedIds = selection.itemIds
                      .map((e) => e.trim())
                      .where((e) => e.isNotEmpty)
                      .toSet();
                  final selectableIds = selection.selectableItemIds
                      .map((e) => e.trim())
                      .where((e) => e.isNotEmpty)
                      .toSet();
                  final unselectedIds = selectableIds
                      .where((id) => !selectedIds.contains(id))
                      .toList(growable: false);
                  if (unselectedIds.isNotEmpty) {
                    HomeworkStore.instance.restoreItemsToWaiting(
                      t.student.id,
                      unselectedIds,
                    );
                  }
                  if (selection.printTodoOnConfirm) {
                    try {
                      await printHomeworkTodoSheet(
                        studentId: t.student.id,
                        studentName: t.student.name,
                        classDateTime: classDateTime,
                        arrivalTime: arrival2,
                        departureTime: now,
                        selectedHomeworkIds: selection.itemIds,
                        selectedBehaviorIds: selection.selectedBehaviorIds,
                        irregularBehaviorCounts:
                            selection.irregularBehaviorCounts,
                        dueDate: selection.dueDate,
                        className: t.classInfo?.name,
                        classEndTime: classDateTime.add(t.duration),
                        setId: t.setId,
                      );
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('알림장 인쇄에 실패했어요: $e')),
                        );
                      }
                    }
                  }
                } catch (e) {
                  print('[ERROR] 출석 기록 동기화 실패: $e');
                }
                return false;
              },
              background: Container(
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.only(left: 16),
                child: const Icon(
                  Icons.arrow_forward_rounded,
                  color: Colors.white54,
                  size: 18,
                ),
              ),
              child: GestureDetector(
                onTapDown: (details) {
                  _lastTagTapPosition = details.globalPosition;
                },
                onTap: () => _handleAttendedCardTap(t),
                onLongPress: () async {
                  _removeClassTagOverlay();
                  setState(() {
                    _attendedSetIds.remove(t.setId);
                    _leavedSetIds.remove(t.setId);
                    _attendTimes.remove(t.setId);
                    _leaveTimes.remove(t.setId);
                    _sideSheetDataDirty = true;
                  });
                  try {
                    final classDateTime = t.classDateTime;
                    final existing = DataManager.instance.getAttendanceRecord(
                      t.student.id,
                      classDateTime,
                    );
                    if (existing?.id != null) {
                      await DataManager.instance.deleteAttendanceRecord(
                        existing!.id!,
                      );
                    }
                    await DataManager.instance.saveOrUpdateAttendance(
                      studentId: t.student.id,
                      classDateTime: classDateTime,
                      classEndTime: existing?.classEndTime ??
                          classDateTime.add(t.duration),
                      className:
                          existing?.className ?? t.classInfo?.name ?? '수업',
                      isPresent: false,
                      arrivalTime: null,
                      departureTime: null,
                      setId: t.setId,
                      sessionTypeId: existing?.sessionTypeId ?? t.classInfo?.id,
                      cycle: existing?.cycle,
                      sessionOrder: existing?.sessionOrder,
                      isPlanned: true,
                      snapshotId: existing?.snapshotId,
                      batchSessionId: existing?.batchSessionId,
                    );
                  } catch (e) {
                    print('[ERROR] 출석 기록 원복 실패: $e');
                  }
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: EdgeInsets.zero,
                  padding: const EdgeInsets.fromLTRB(0, 9.5, 18, 9.5),
                  decoration: BoxDecoration(
                    // 등원 완료(출석) 카드: 테두리 제거
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: attendedChild,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: _buildHomeworkChipsReactive(t)),
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
              final existing = DataManager.instance.getAttendanceRecord(
                t.student.id,
                classDateTime,
              );
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
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('다른 기기에서 먼저 수정되었습니다. 새로고침 후 다시 시도하세요.'),
                    ),
                  );
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
            border: Border.all(color: borderColor, width: 1.5),
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
      fontSize: status == 'attended' ? 19 : 16,
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
              unawaited(
                ConsultTrialLessonService.instance.setLeaved(
                  slotId: s.id,
                  leaved: true,
                ),
              );
            },
            onSecondaryTap: () {
              // 실수 취소: 등원/하원 기록 제거
              unawaited(
                ConsultTrialLessonService.instance.setArrived(
                  slotId: s.id,
                  arrived: false,
                ),
              );
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
                  Text(
                    s.title,
                    style: nameStyle,
                    overflow: TextOverflow.ellipsis,
                  ),
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
        unawaited(
          ConsultTrialLessonService.instance.setArrived(
            slotId: s.id,
            arrived: true,
          ),
        );
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
        child: Text(s.title, style: nameStyle, overflow: TextOverflow.ellipsis),
      ),
    );
  }

  Widget _buildHomeworkChipsReactive(_AttendanceTarget t) {
    return ValueListenableBuilder<int>(
      valueListenable: HomeworkAssignmentStore.instance.revision,
      builder: (context, assignRev, _) {
        final studentId = t.student.id;
        final lastRev = _homeworkChipAssignRevisionByStudent[studentId];
        if (lastRev != assignRev) {
          _homeworkChipAssignRevisionByStudent[studentId] = assignRev;
          _activeAssignmentsFutureByStudent[studentId] =
              HomeworkAssignmentStore.instance.loadActiveAssignments(studentId);
        }
        final assignmentsFuture = _activeAssignmentsFutureByStudent.putIfAbsent(
          studentId,
          () =>
              HomeworkAssignmentStore.instance.loadActiveAssignments(studentId),
        );
        return FutureBuilder<List<HomeworkAssignmentDetail>>(
          future: assignmentsFuture,
          builder: (context, snapshot) {
            final assignments =
                snapshot.data ?? const <HomeworkAssignmentDetail>[];
            final hiddenAssignedItemIds = assignments
                .where(_isReservationAssignment)
                .map((a) => a.homeworkItemId.trim())
                .where((id) => id.isNotEmpty)
                .toSet();
            final Map<String, String> groupTitleById = <String, String>{};
            for (final assignment in assignments) {
              final groupId = (assignment.groupId ?? '').trim();
              final groupTitle = (assignment.groupTitleSnapshot ?? '').trim();
              if (groupId.isEmpty || groupTitle.isEmpty) continue;
              groupTitleById.putIfAbsent(groupId, () => groupTitle);
            }
            return ValueListenableBuilder<int>(
              valueListenable: HomeworkStore.instance.revision,
              builder: (context, _rev, _) {
                return AnimatedBuilder(
                  animation: _uiAnimController,
                  builder: (context, _) {
                    return _buildHomeworkChipsScroller(
                      t,
                      hiddenItemIds: hiddenAssignedItemIds,
                      groupTitleById: groupTitleById,
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  bool _isReservationAssignment(HomeworkAssignmentDetail assignment) {
    final note = (assignment.note ?? '').trim();
    return note == HomeworkAssignmentStore.reservationNote;
  }

  // 가로 스크롤러: 칩이 넘치면 스크롤, 줄바꿈 금지
  Widget _buildHomeworkChipsScroller(
    _AttendanceTarget t, {
    Set<String> hiddenItemIds = const <String>{},
    Map<String, String> groupTitleById = const <String, String>{},
  }) {
    final chips = _buildHomeworkChipsOnce(
      t,
      hiddenItemIds: hiddenItemIds,
      groupTitleById: groupTitleById,
    );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Row(children: chips),
      ),
    );
  }

  // 왼쪽 사이드시트 과제 칩에서는 단원 숫자 prefix만 숨긴다.
  // 예) "1.2.(3) 함수의 극한" -> "함수의 극한"
  String _chipDisplayTitle(String rawTitle) {
    final trimmed = rawTitle.trim();
    final stripped = trimmed.replaceFirst(
      RegExp(r'^\d+(?:\.(?:\d+|\(\d+\)))*\s+'),
      '',
    );
    return stripped.isEmpty ? trimmed : stripped;
  }

  List<Widget> _buildHomeworkChipsOnce(
    _AttendanceTarget t, {
    Set<String> hiddenItemIds = const <String>{},
    Map<String, String> groupTitleById = const <String, String>{},
  }) {
    final studentId = t.student.id;
    final groups = HomeworkStore.instance.groups(studentId);
    final List<Widget> chips = [];
    const Color statusAccent = Color(0xFF33A373);
    void addGroupTitleChip(
      String rawTitle, {
      int visualPhase = 1, // 1:대기 2:수행 3:제출 4:확인
    }) {
      final chipTitle = _chipDisplayTitle(rawTitle);
      if (chipTitle.trim().isEmpty) return;

      if (chips.isNotEmpty) chips.add(const SizedBox(width: 8));
      chips.add(
        Builder(
          builder: (context) {
            final tick = _uiAnimController.value;
            final phase4Pulse = 0.5 + 0.5 * math.sin(2 * math.pi * tick);
            const style = TextStyle(
              color: Color(0xFFEAF2F2),
              fontSize: 14,
              fontWeight: FontWeight.w600,
              height: 1.1,
            );
            final painter = TextPainter(
              text: TextSpan(text: chipTitle, style: style),
              maxLines: 1,
              textDirection: TextDirection.ltr,
              textScaleFactor: MediaQuery.of(context).textScaleFactor,
            )..layout(minWidth: 0, maxWidth: double.infinity);
            const double leftPad = 14;
            const double rightPad = 16;
            final double width = painter.width + leftPad + rightPad + 2 + 6.0;
            final Border border = switch (visualPhase) {
              2 => Border.all(color: statusAccent.withOpacity(0.9), width: 2),
              3 => Border.all(color: Colors.transparent, width: 2),
              4 => Border.all(
                  color: Color.lerp(
                        Colors.white24,
                        statusAccent.withOpacity(0.9),
                        phase4Pulse,
                      ) ??
                      Colors.white24,
                  width: 2,
                ),
              _ => Border.all(color: Colors.white24, width: 1),
            };
            Widget chipInner = Container(
              height: 40,
              padding: const EdgeInsets.fromLTRB(leftPad, 0, rightPad, 0),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: border,
              ),
              child: Text(
                chipTitle,
                style: style,
                textAlign: TextAlign.center,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
              ),
            );
            if (visualPhase == 3) {
              chipInner = RepaintBoundary(
                child: CustomPaint(
                  foregroundPainter: _RotatingBorderPainter(
                    baseColor: statusAccent,
                    tick: tick,
                    strokeWidth: 2.0,
                    cornerRadius: 6.0,
                  ),
                  child: chipInner,
                ),
              );
            }

            return Tooltip(
              message: chipTitle,
              child:
                  SizedBox(width: width.clamp(70.0, 560.0), child: chipInner),
            );
          },
        ),
      );
    }

    for (final group in groups) {
      final children = HomeworkStore.instance
          .itemsInGroup(studentId, group.id)
          .where((e) => e.status != HomeworkStatus.completed)
          .where((e) => !hiddenItemIds.contains(e.id))
          .toList();
      if (children.isEmpty) continue;
      final bool hasRunningChild =
          children.any((e) => e.runStart != null || e.phase == 2);
      final bool hasSubmittedChild = children.any((e) => e.phase == 3);
      final bool hasConfirmedChild = children.any((e) => e.phase == 4);
      final int groupPhase = hasRunningChild
          ? 2
          : (hasSubmittedChild ? 3 : (hasConfirmedChild ? 4 : 1));

      final fromAssignment = (groupTitleById[group.id] ?? '').trim();
      final fromGroup = group.title.trim();
      final rawTitle = fromAssignment.isNotEmpty
          ? fromAssignment
          : (fromGroup.isNotEmpty ? fromGroup : '그룹 과제');
      addGroupTitleChip(rawTitle, visualPhase: groupPhase);
    }

    // 그룹 메타가 아직 동기화되지 않은 경우에도, 할당 스냅샷의 그룹명으로 칩을 복원한다.
    if (chips.isEmpty && groupTitleById.isNotEmpty) {
      final seenTitles = <String>{};
      final entries = groupTitleById.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      for (final entry in entries) {
        final title = entry.value.trim();
        if (title.isEmpty) continue;
        if (!seenTitles.add(title)) continue;
        addGroupTitleChip(title);
      }
    }
    return chips;
  }
}

class _SideSheetDateHeader extends StatelessWidget {
  final DateTime date;
  final VoidCallback onMoveToYesterday;
  final VoidCallback onMoveToToday;

  const _SideSheetDateHeader({
    required this.date,
    required this.onMoveToYesterday,
    required this.onMoveToToday,
  });

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);
    final isToday = date.year == todayDate.year &&
        date.month == todayDate.month &&
        date.day == todayDate.day;
    final yesterday = todayDate.subtract(const Duration(days: 1));
    final isYesterday = date.year == yesterday.year &&
        date.month == yesterday.month &&
        date.day == yesterday.day;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: isYesterday ? '이미 어제 날짜를 보고 있어요' : '어제로 이동',
          child: IconButton(
            onPressed: isYesterday ? null : onMoveToYesterday,
            icon: Icon(
              Icons.chevron_left_rounded,
              color: isYesterday ? Colors.white24 : Colors.white70,
              size: 30,
            ),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 38, minHeight: 30),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          _getTodayDateString(date),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 30,
            fontWeight: FontWeight.w800,
            height: 1.0,
          ),
        ),
        if (!isToday) ...[
          const SizedBox(width: 10),
          TextButton(
            onPressed: onMoveToToday,
            style: TextButton.styleFrom(
              foregroundColor: Colors.white70,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text(
              '오늘',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ],
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
  final OverrideType?
      overrideType; // null이면 일반 수업, replace=보강(파란줄), add=추가수업(초록줄)

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

  const _LeavedDialogEntry({
    required this.target,
    this.arrival,
    this.departure,
  });
}

// OverlayEntry 툴팁을 띄우는 호버 영역 위젯
class _TooltipHoverArea extends StatefulWidget {
  final String main;
  final String tooltip;
  final Color textColor;
  final void Function(BuildContext, Offset, String) showTooltip;
  final VoidCallback hideTooltip;
  const _TooltipHoverArea({
    required this.main,
    required this.tooltip,
    required this.showTooltip,
    required this.hideTooltip,
    required this.textColor,
  });
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
        style: TextStyle(
          color: widget.textColor,
          fontSize: 16,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

String _formatTime(DateTime dt) {
  return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
}

// 날짜/요일 포맷 함수 추가
String _getTodayDateString([DateTime? date]) {
  final now = date ?? DateTime.now();
  final week = ['월', '화', '수', '목', '금', '토', '일'];
  return '${now.year}.${now.month.toString().padLeft(2, '0')}.${now.day.toString().padLeft(2, '0')} (${week[now.weekday - 1]})';
}

String _getTodayDateShortString([DateTime? date]) {
  final now = date ?? DateTime.now();
  final week = ['월', '화', '수', '목', '금', '토', '일'];
  return '${now.month.toString().padLeft(2, '0')}.${now.day.toString().padLeft(2, '0')} (${week[now.weekday - 1]})';
}

// 수업 태그 정의(메모리 전용)
class _ClassTag {
  final String name;
  final Color color;
  final IconData icon;
  const _ClassTag({
    required this.name,
    required this.color,
    required this.icon,
  });
}

// UI 전용 칩 상태 정의
enum _UiPhase {
  // 수행 상태는 서버 running 여부로 표현, 아래 값들은 UI 전용 표시 상태
  submitted, // 제출: 회전 테두리
  confirmed, // 확인: 깜빡임
  waiting, // 대기: 비활성화
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
      _uiPhases.putIfAbsent(studentId, () => <String, _UiPhase>{})[itemId] =
          phase;
    });
  }

  Future<void> _openHomeworkEditDialog(String studentId, String itemId) async {
    final item = HomeworkStore.instance.getById(studentId, itemId);
    if (item == null) return;
    final edited = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => HomeworkEditDialog(
        initialTitle: item.title,
        initialBody: item.body,
        initialColor: item.color,
        initialType: item.type,
        initialPage: item.page,
        initialCount: item.count,
        initialContent: item.content,
      ),
    );
    if (edited == null) return;
    final countStr = (edited['count'] as String?)?.trim();
    final updated = HomeworkItem(
      id: item.id,
      title: (edited['title'] as String).trim(),
      body: (edited['body'] as String).trim(),
      color: (edited['color'] as Color),
      flowId: item.flowId,
      type: (edited['type'] as String?)?.trim(),
      page: (edited['page'] as String?)?.trim(),
      count: (countStr == null || countStr.isEmpty)
          ? null
          : int.tryParse(countStr),
      content: (edited['content'] as String?)?.trim(),
      bookId: item.bookId,
      gradeLabel: item.gradeLabel,
      sourceUnitLevel: item.sourceUnitLevel,
      sourceUnitPath: item.sourceUnitPath,
      unitMappings: item.unitMappings == null
          ? null
          : List<Map<String, dynamic>>.from(
              item.unitMappings!.map((e) => Map<String, dynamic>.from(e)),
            ),
      defaultSplitParts: item.defaultSplitParts,
      checkCount: item.checkCount,
      createdAt: item.createdAt,
      updatedAt: DateTime.now(),
      status: item.status,
      phase: item.phase,
      accumulatedMs: item.accumulatedMs,
      cycleBaseAccumulatedMs: item.cycleBaseAccumulatedMs,
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
  Future<void> _openClassTagDialog(
    _AttendanceTarget target, {
    Offset? anchor,
  }) async {
    final List<_ClassTagEvent> initialApplied = List<_ClassTagEvent>.from(
      _classTagEventsBySetId[target.setId] ?? const [],
    );
    List<_ClassTagEvent> workingApplied = List<_ClassTagEvent>.from(
      initialApplied,
    );
    // 프리셋에서 즉시 로드하여 사용 가능한 태그 구성
    final presets = await TagPresetService.instance.loadPresets();
    final recordPreset = presets.firstWhereOrNull((p) => p.name.trim() == '기록');
    final recordTag = _ClassTag(
      name: '기록',
      color: recordPreset?.color ?? const Color(0xFF1976D2),
      icon: recordPreset?.icon ?? Icons.edit_note,
    );
    List<_ClassTag> workingAvailable = presets
        .where((p) => p.name.trim() != '기록')
        .map((p) => _ClassTag(name: p.name, color: p.color, icon: p.icon))
        .toList();

    void _applyWorkingTags() {
      setState(() {
        _classTagEventsBySetId[target.setId] = List<_ClassTagEvent>.from(
          workingApplied,
        );
      });
      final events = workingApplied
          .map(
            (e) => TagEvent(
              tagName: e.tag.name,
              colorValue: e.tag.color.value,
              iconCodePoint: e.tag.icon.codePoint,
              timestamp: e.timestamp,
              note: e.note,
            ),
          )
          .toList();
      TagStore.instance.setEventsForSet(
        target.setId,
        target.student.id,
        events,
      );
    }

    Future<void> _handleTagPressed(
      BuildContext overlayCtx,
      void Function(void Function()) setLocal,
      _ClassTag tag,
    ) async {
      final now = DateTime.now();
      setLocal(() {
        workingApplied.add(_ClassTagEvent(tag: tag, timestamp: now));
      });
      TagStore.instance.appendEvent(
        target.setId,
        target.student.id,
        TagEvent(
          tagName: tag.name,
          colorValue: tag.color.value,
          iconCodePoint: tag.icon.codePoint,
          timestamp: now,
          note: null,
        ),
      );
      _applyWorkingTags();
      _removeClassTagOverlay();
    }

    Future<void> _handleRecordPressed() async {
      _removeClassTagOverlay();
      await Future<void>.delayed(Duration.zero);
      final note = await _openRecordNoteDialog(context);
      if (note == null || note.trim().isEmpty) return;
      final trimmed = note.trim();
      final now = DateTime.now();
      workingApplied.add(
        _ClassTagEvent(tag: recordTag, timestamp: now, note: trimmed),
      );
      TagStore.instance.appendEvent(
        target.setId,
        target.student.id,
        TagEvent(
          tagName: recordTag.name,
          colorValue: recordTag.color.value,
          iconCodePoint: recordTag.icon.codePoint,
          timestamp: now,
          note: trimmed,
        ),
      );
      _applyWorkingTags();
    }

    Future<void> _handleHomeworkPressed() async {
      _removeClassTagOverlay();
      await Future<void>.delayed(Duration.zero);
      final enabledFlows = await ensureEnabledFlowsForHomework(
        context,
        target.student.id,
      );
      if (enabledFlows.isEmpty) return;
      final result = await showDialog<dynamic>(
        context: context,
        builder: (ctx) => HomeworkQuickAddProxyDialog(
          studentId: target.student.id,
          flows: enabledFlows,
          initialFlowId: enabledFlows.first.id,
          initialTitle: '',
          initialColor: const Color(0xFF1976D2),
        ),
      );
      if (result is Map<String, dynamic> &&
          result['studentId'] == target.student.id) {
        final action = (result['action'] as String?)?.trim() ?? 'add';
        final isReserve = action == 'reserve';
        final groupMode = result['groupMode'] == true;
        if (groupMode) {
          final rawItems = result['items'];
          final entries = <Map<String, dynamic>>[];
          if (rawItems is List) {
            for (final e in rawItems) {
              if (e is Map<String, dynamic>) {
                entries.add(Map<String, dynamic>.from(e));
              } else if (e is Map) {
                entries.add(Map<String, dynamic>.from(e));
              }
            }
          }
          if (entries.isEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('하위 과제를 1개 이상 추가하세요.')),
            );
            return;
          }
          final createdItems =
              await HomeworkStore.instance.createGroupWithWaitingItems(
            studentId: target.student.id,
            groupTitle: (result['groupTitle'] as String?)?.trim() ?? '',
            flowId: (result['flowId'] as String?)?.trim(),
            items: entries,
          );
          if (createdItems.isEmpty) {
            if (!context.mounted) return;
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('그룹 과제 생성에 실패했어요.')));
            return;
          }
          if (isReserve) {
            await HomeworkAssignmentStore.instance.recordAssignments(
              target.student.id,
              createdItems,
              note: HomeworkAssignmentStore.reservationNote,
              splitPartsByItem: <String, int>{
                for (final hw in createdItems)
                  hw.id: hw.defaultSplitParts.clamp(1, 4).toInt(),
              },
            );
          }
          if (!context.mounted) return;
          final childCount = createdItems.length;
          final msg = isReserve
              ? '그룹 예약 과제(하위 ${childCount}개)를 추가했어요.'
              : '그룹 과제(하위 ${childCount}개)를 추가했어요.';
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(msg)));
          return;
        }
        final flowId = result['flowId'] as String?;
        final dynamic multiRaw = result['items'];
        final entries = <Map<String, dynamic>>[];
        final createdItems = <HomeworkItem>[];
        if (multiRaw is List) {
          for (final e in multiRaw) {
            if (e is Map<String, dynamic>) entries.add(e);
          }
        } else {
          entries.add(result);
        }
        int _parseSplitParts(dynamic value) {
          if (value is int) return value.clamp(1, 4).toInt();
          if (value is num) return value.toInt().clamp(1, 4).toInt();
          if (value is String) {
            return (int.tryParse(value) ?? 1).clamp(1, 4).toInt();
          }
          return 1;
        }

        for (final entry in entries) {
          final countStr = (entry['count'] as String?)?.trim();
          final splitParts = _parseSplitParts(
            entry['splitParts'] ?? result['splitParts'],
          );
          final created = HomeworkStore.instance.add(
            result['studentId'],
            title: (entry['title'] as String?) ?? '',
            body: (entry['body'] as String?) ?? '',
            color: (entry['color'] as Color?) ?? const Color(0xFF1976D2),
            flowId: flowId,
            type: (entry['type'] as String?)?.trim(),
            page: (entry['page'] as String?)?.trim(),
            count: (countStr == null || countStr.isEmpty)
                ? null
                : int.tryParse(countStr),
            content: (entry['content'] as String?)?.trim(),
            bookId: (entry['bookId'] as String?)?.trim(),
            gradeLabel: (entry['gradeLabel'] as String?)?.trim(),
            sourceUnitLevel: (entry['sourceUnitLevel'] as String?)?.trim(),
            sourceUnitPath: (entry['sourceUnitPath'] as String?)?.trim(),
            unitMappings: (entry['unitMappings'] is List)
                ? List<Map<String, dynamic>>.from(
                    (entry['unitMappings'] as List).whereType<Map>().map(
                          (e) => Map<String, dynamic>.from(e),
                        ),
                  )
                : null,
            defaultSplitParts: splitParts,
          );
          createdItems.add(created);
        }
        if (isReserve && createdItems.isNotEmpty) {
          await HomeworkAssignmentStore.instance.recordAssignments(
            target.student.id,
            createdItems,
            note: HomeworkAssignmentStore.reservationNote,
            splitPartsByItem: <String, int>{
              for (final hw in createdItems)
                hw.id: hw.defaultSplitParts.clamp(1, 4).toInt(),
            },
          );
        }
        final String msg = isReserve
            ? (entries.length > 1
                ? '예약 과제를 ${entries.length}개 추가했어요.'
                : '예약 과제를 추가했어요.')
            : (entries.length > 1
                ? '과제를 ${entries.length}개 추가했어요.'
                : '과제를 추가했어요.');
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(msg)));
      }
    }

    void _removeAppliedAt(void Function(void Function()) setLocal, int index) {
      setLocal(() {
        workingApplied.removeAt(index);
      });
      _applyWorkingTags();
    }

    _removeClassTagOverlay();
    final overlay = Overlay.of(context);
    final screenW = MediaQuery.of(context).size.width;
    final screenH = MediaQuery.of(context).size.height;
    final rect = _getSideSheetRect();
    final sheetWidth = rect?.width ?? _sideSheetWidth;
    final leftEdge = rect?.right ?? sheetWidth;
    final baseWidth = (sheetWidth - 24).clamp(260.0, 420.0).toDouble();
    final available = (screenW - leftEdge).clamp(160.0, screenW).toDouble();
    final panelWidth = ((baseWidth > available ? available : baseWidth) * 0.7)
        .clamp(160.0, available)
        .toDouble();
    const double headerOffset = 14.0;
    final anchorPos = anchor ?? Offset(leftEdge, 120);
    final double top = (anchorPos.dy - headerOffset).clamp(0.0, screenH);
    _armClassTagBarrier();
    _classTagOverlay = OverlayEntry(
      builder: (overlayCtx) {
        return Stack(
          children: [
            Positioned.fill(
              child: ValueListenableBuilder<bool>(
                valueListenable: _classTagBarrierActive,
                builder: (_, active, __) {
                  return IgnorePointer(
                    ignoring: !active,
                    child: GestureDetector(
                      onTap: _removeClassTagOverlay,
                      behavior: HitTestBehavior.opaque,
                      child: Container(color: Colors.transparent),
                    ),
                  );
                },
              ),
            ),
            Positioned(
              left: leftEdge + 10,
              top: top,
              width: panelWidth,
              child: Material(
                color: Colors.transparent,
                child: StatefulBuilder(
                  builder: (ctx, setLocal) {
                    return Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF0B1112),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF223131)),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black54,
                            blurRadius: 14,
                            offset: Offset(0, 6),
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${target.student.name} · ${_getTodayDateShortString(_sideSheetAnchorDate)}',
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              IconButton(
                                onPressed: _removeClassTagOverlay,
                                icon: const Icon(
                                  Icons.close,
                                  color: Colors.white54,
                                  size: 18,
                                ),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                  minWidth: 28,
                                  minHeight: 28,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            height: 45.2,
                            child: OutlinedButton.icon(
                              onPressed: _handleHomeworkPressed,
                              icon: const Icon(
                                Icons.playlist_add,
                                size: 16,
                                color: Color(0xFF9FB3B3),
                              ),
                              label: const Text(
                                '과제',
                                style: TextStyle(
                                  color: Color(0xFF9FB3B3),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xFF9FB3B3),
                                side: const BorderSide(
                                  color: Color(0xFF4D5A5A),
                                  width: 1.2,
                                ),
                                backgroundColor: Colors.transparent,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                minimumSize: const Size.fromHeight(45.2),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                shape: const StadiumBorder(),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            height: 45.2,
                            child: FilledButton.icon(
                              onPressed: _handleRecordPressed,
                              icon: const Icon(
                                Icons.edit_note,
                                size: 16,
                                color: Colors.white,
                              ),
                              label: const Text(
                                '기록',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFF33A373),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                minimumSize: const Size.fromHeight(45.2),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                shape: const StadiumBorder(),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: workingAvailable.map((tag) {
                              return ActionChip(
                                onPressed: () =>
                                    _handleTagPressed(ctx, setLocal, tag),
                                backgroundColor: const Color(0xFF0B1112),
                                label: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(tag.icon, color: tag.color, size: 16),
                                    const SizedBox(width: 6),
                                    Text(
                                      tag.name,
                                      style: const TextStyle(
                                        color: Colors.white,
                                      ),
                                    ),
                                  ],
                                ),
                                shape: const StadiumBorder(
                                  side: BorderSide(
                                    color: Color(0xFF3A3F44),
                                    width: 1.0,
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                          const SizedBox(height: 10),
                          const Divider(
                            color: Color(0xFF223131),
                            height: 12,
                            thickness: 1,
                          ),
                          const SizedBox(height: 8),
                          if (workingApplied.isEmpty)
                            const Text(
                              '아직 추가된 태그가 없습니다.',
                              style: TextStyle(color: Colors.white38),
                            )
                          else
                            Column(
                              children: [
                                for (int i = workingApplied.length - 1;
                                    i >= 0;
                                    i--) ...[
                                  Builder(
                                    builder: (context) {
                                      final e = workingApplied[i];
                                      return Container(
                                        margin: const EdgeInsets.only(
                                          bottom: 8,
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 8,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF22262C),
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          border: Border.all(
                                            color: const Color(0xFF3A3F44),
                                            width: 1,
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            Icon(
                                              e.tag.icon,
                                              color: e.tag.color,
                                              size: 16,
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                e.note != null &&
                                                        e.note!.isNotEmpty
                                                    ? '${e.tag.name} · ${e.note}'
                                                    : e.tag.name,
                                                style: const TextStyle(
                                                  color: Colors.white70,
                                                ),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                            Text(
                                              _formatTime(e.timestamp),
                                              style: const TextStyle(
                                                color: Colors.white54,
                                                fontSize: 12,
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                            InkWell(
                                              onTap: () =>
                                                  _removeAppliedAt(setLocal, i),
                                              child: const Icon(
                                                Icons.close,
                                                color: Colors.white54,
                                                size: 14,
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                                ],
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
        );
      },
    );
    overlay.insert(_classTagOverlay!);
  }

  Future<_ClassTag?> _createNewClassTag(BuildContext context) async {
    final TextEditingController nameController =
        ImeAwareTextEditingController();
    final List<Color> palette = const [
      Color(0xFFEF5350),
      Color(0xFFAB47BC),
      Color(0xFF7E57C2),
      Color(0xFF5C6BC0),
      Color(0xFF42A5F5),
      Color(0xFF26A69A),
      Color(0xFF66BB6A),
      Color(0xFFFFCA28),
      Color(0xFFF57C00),
      Color(0xFF8D6E63),
      Color(0xFFBDBDBD),
      Color(0xFF90A4AE),
    ];
    final List<IconData> iconChoices = const [
      Icons.bedtime,
      Icons.phone_iphone,
      Icons.edit_note,
      Icons.lightbulb,
      Icons.flag,
      Icons.psychology,
      Icons.sports_esports,
      Icons.timer,
      Icons.warning,
      Icons.check_circle,
      Icons.book,
      Icons.menu_book,
      Icons.school,
      Icons.sick,
      Icons.mood_bad,
      Icons.thumb_down,
      Icons.thumb_up,
      Icons.self_improvement,
      Icons.local_cafe,
      Icons.code,
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
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              title: const Text(
                '새 태그 만들기',
                style: TextStyle(color: Colors.white, fontSize: 20),
              ),
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
                          border: OutlineInputBorder(
                            borderSide: BorderSide(color: Colors.white24),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderSide: BorderSide(color: Colors.white24),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderSide: BorderSide(color: Color(0xFF1976D2)),
                          ),
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
                                  border: Border.all(
                                    color: c == selectedColor
                                        ? Colors.white
                                        : Colors.white24,
                                    width: c == selectedColor ? 2 : 1,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        '아이콘',
                        style: TextStyle(color: Colors.white70),
                      ),
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
                                  border: Border.all(
                                    color: ic == selectedIcon
                                        ? Colors.white
                                        : Colors.white24,
                                  ),
                                ),
                                child: Icon(
                                  ic,
                                  color: ic == selectedIcon
                                      ? Colors.white
                                      : Colors.white70,
                                  size: 20,
                                ),
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
                  child: const Text(
                    '취소',
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
                ElevatedButton(
                  onPressed: () {
                    final name = nameController.text.trim();
                    if (name.isEmpty) {
                      Navigator.of(ctx).pop(null);
                      return;
                    }
                    Navigator.of(ctx).pop(
                      _ClassTag(
                        name: name,
                        color: selectedColor,
                        icon: selectedIcon,
                      ),
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1976D2),
                    foregroundColor: Colors.white,
                  ),
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
    return showDialog<String?>(
      context: context,
      builder: (_) => const _RecordNoteDialog(),
    );
  }
}

class _RecordNoteDialog extends StatefulWidget {
  const _RecordNoteDialog();

  @override
  State<_RecordNoteDialog> createState() => _RecordNoteDialogState();
}

class _RecordNoteDialogState extends State<_RecordNoteDialog> {
  late final ImeAwareTextEditingController _controller;
  late final FocusNode _focusNode;
  bool _didRequestFocus = false;

  @override
  void initState() {
    super.initState();
    _controller = ImeAwareTextEditingController();
    _focusNode = FocusNode();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didRequestFocus) return;
    _didRequestFocus = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route?.isCurrent != true) return;
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _handleSave() {
    FocusScope.of(context).unfocus();
    _controller.value = _controller.value.copyWith(composing: TextRange.empty);
    final text = _controller.text.trim();
    Navigator.of(context).pop(text.isEmpty ? null : text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: kDlgBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: kDlgBorder),
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      title: const Text(
        '기록 입력',
        style: TextStyle(
          color: kDlgText,
          fontSize: 20,
          fontWeight: FontWeight.w900,
        ),
      ),
      content: SizedBox(
        width: 520,
        child: TextField(
          controller: _controller,
          focusNode: _focusNode,
          maxLines: 4,
          decoration: InputDecoration(
            hintText: '수업 중 있었던 일을 간단히 적어주세요',
            hintStyle: const TextStyle(color: kDlgTextSub),
            filled: true,
            fillColor: kDlgFieldBg,
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: kDlgBorder),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: kDlgAccent),
            ),
          ),
          style: const TextStyle(color: kDlgText),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
          child: const Text('취소'),
        ),
        ElevatedButton(
          onPressed: _handleSave,
          style: ElevatedButton.styleFrom(
            backgroundColor: kDlgAccent,
            foregroundColor: Colors.white,
          ),
          child: const Text('저장'),
        ),
      ],
    );
  }
}

// 회전 보더 페인터: 내부 child의 레이아웃을 바꾸지 않고, 외곽선만 회전시키며 그린다
class _RotatingBorderPainter extends CustomPainter {
  final Color baseColor;
  final double tick; // 0..1
  final double strokeWidth;
  final double cornerRadius;
  _RotatingBorderPainter({
    required this.baseColor,
    required this.tick,
    this.strokeWidth = 2.0,
    this.cornerRadius = 8.0,
  }) : super();
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectXY(
      rect.deflate(strokeWidth / 2),
      cornerRadius,
      cornerRadius,
    );
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
    return oldDelegate.tick != tick ||
        oldDelegate.baseColor != baseColor ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.cornerRadius != cornerRadius;
  }
}
