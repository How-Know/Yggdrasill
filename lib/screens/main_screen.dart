import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/navigation_rail.dart';
import '../widgets/student_registration_dialog.dart';
import '../services/data_manager.dart';
import '../models/attendance_record.dart';
import 'student/student_screen.dart';
import 'timetable/timetable_screen.dart';
import 'home/home_screen.dart';
import 'settings/settings_screen.dart';
import 'resources/resources_screen.dart';
import 'learning/learning_screen.dart';
import '../services/tag_store.dart';
import 'learning/tag_preset_dialog.dart';
import '../models/student.dart';
import '../models/group_info.dart';
import '../models/student_view_type.dart';
import '../widgets/main_fab_alternative.dart';
import '../models/class_info.dart';
import '../models/session_override.dart';
import '../models/student_time_block.dart';
import 'dart:collection';
import '../models/education_level.dart';
import 'package:collection/collection.dart';
import '../services/homework_store.dart';
import 'learning/homework_quick_add_proxy_dialog.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with TickerProviderStateMixin {
  int _selectedIndex = 0;
  bool _isSideSheetOpen = false;
  late AnimationController _rotationAnimation;
  late Animation<double> _sideSheetAnimation;
  bool _isFabExpanded = false;
  late AnimationController _fabController;
  late Animation<double> _fabScaleAnimation;
  late Animation<double> _fabOpacityAnimation;
  // 진단용: 사이드 시트 완료 상태 전이 추적
  bool _sideSheetWasComplete = false;
  // 사이드 시트 스크롤 컨트롤러 (경고/오버플로 방지)
  late final ScrollController _leavedScrollCtrl;
  late final ScrollController _attendedScrollCtrl;
  late final ScrollController _waitingScrollCtrl;
  
  // StudentScreen 관련 상태
  final GlobalKey<StudentScreenState> _studentScreenKey = GlobalKey<StudentScreenState>();
  StudentViewType _viewType = StudentViewType.all;
  final List<GroupInfo> _groups = [];
  final List<Student> _students = [];
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  final Set<GroupInfo> _expandedGroups = {};
  double _fabBottomPadding = 16.0;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _snackBarController;
  int? _prevIndex;

  // 출석/하원 상태 관리
  final Set<String> _attendedSetIds = {}; // 출석한 setId
  final Set<String> _leavedSetIds = {};   // 하원한 setId

  // 오늘 등원해야 하는 학생(setId별) 리스트 추출
  List<_AttendanceTarget> getTodayAttendanceTargets() {
    final now = DateTime.now();
    final todayIdx = now.weekday - 1; // 0:월~6:일
    final blocks = DataManager.instance.studentTimeBlocks
        .where((b) => b.dayIndex == todayIdx)
        .toList();
    // setId별로 묶기
    final setMap = <String, List<StudentTimeBlock>>{};
    for (final b in blocks) {
      if (b.setId != null) {
        setMap.putIfAbsent(b.setId!, () => []).add(b);
      }
    }
    final Map<String, _AttendanceTarget> byKey = {}; // key -> target
    for (final entry in setMap.entries) {
      final block = entry.value.first;
      final studentList = DataManager.instance.students
          .where((s) => s.student.id == block.studentId)
          .toList();
      final StudentWithInfo? student = studentList.isNotEmpty ? studentList.first : null;
      final classList = block.sessionTypeId != null
          ? DataManager.instance.classes
              .where((c) => c.id == block.sessionTypeId)
              .toList()
          : [];
      final ClassInfo? classInfo = classList.isNotEmpty ? classList.first : null;
      if (student != null) {
        final key = '${student.student.id}@${now.year}-${now.month}-${now.day} ${block.startHour}:${block.startMinute}';
        byKey[key] = _AttendanceTarget(
          setId: entry.key,
          student: student.student,
          classInfo: classInfo,
          startHour: block.startHour,
          startMinute: block.startMinute,
          duration: block.duration,
          overrideType: null,
        );
      }
    }

    // 보강/추가수업(오버라이드)도 대상에 포함: 오늘 날짜의 replacementClassDateTime 기준
    final overrides = DataManager.instance.sessionOverridesNotifier.value;
    for (final ov in overrides) {
      if (ov.status == OverrideStatus.canceled) continue;
      if (ov.reason != OverrideReason.makeup) continue; // 보강만 대상
      if (!(ov.overrideType == OverrideType.add || ov.overrideType == OverrideType.replace)) continue;
      final repl = ov.replacementClassDateTime;
      if (repl == null) continue;
      if (!(repl.year == now.year && repl.month == now.month && repl.day == now.day)) continue;

      // 학생/수업 조회
      final student = DataManager.instance.students.firstWhereOrNull((s) => s.student.id == ov.studentId);
      if (student == null) continue;
      final ClassInfo? classInfo = ov.sessionTypeId != null
          ? DataManager.instance.classes.firstWhereOrNull((c) => c.id == ov.sessionTypeId)
          : null;

      final startHour = repl.hour;
      final startMinute = repl.minute;
      final duration = Duration(minutes: ov.durationMinutes ?? DataManager.instance.academySettings.lessonDuration);
      final key = '${ov.studentId}@${repl.year}-${repl.month}-${repl.day} ${startHour}:${startMinute}';
      // 보강/추가수업이 같은 학생/시간이면 override로 대체하여 언더라인 표시
      byKey[key] = _AttendanceTarget(
        setId: ov.id, // 고유 식별자로 사용
        student: student.student,
        classInfo: classInfo,
        startHour: startHour,
        startMinute: startMinute,
        duration: duration,
        overrideType: ov.overrideType,
      );
    }
    // 시작시간 기준 정렬
    final result = byKey.values.toList()..sort((a, b) => a.startTime.compareTo(b.startTime));
    return result;
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
    print('[DEBUG] _showTooltip called: position= [38;5;246m$position [0m, text=$text');
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
    print('[DEBUG] _showTooltip OverlayEntry inserted');
  }
  void _removeTooltip() {
    print('[DEBUG] _removeTooltip called');
    _tooltipOverlay?.remove();
    _tooltipOverlay = null;
  }

  // 카드 레이아웃 상수 (클래스 필드로 이동)
  static const double _cardHeight = 42.0;
  static const double _cardMargin = 4.0;
  static const double _cardSpacing = 8.0;
  static const double _attendedRunSpacing = 16.0;
  static const int _leavedMaxLines = 3;
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
    _rotationAnimation = AnimationController(
      duration: const Duration(milliseconds: 240),
      vsync: this,
    );
    // 진단용: 애니메이션 진행도 및 상태 로깅
    _rotationAnimation.addListener(() {
      final v = _rotationAnimation.value;
      if (v == 0.0 || v == 1.0) {
        print('[SIDE_SHEET][controller.value]=$v');
      }
    });
    _rotationAnimation.addStatusListener((status) {
      print('[SIDE_SHEET][controller.status]=$status');
    });
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
    // 스크롤 컨트롤러 초기화
    _leavedScrollCtrl = ScrollController();
    _attendedScrollCtrl = ScrollController();
    _waitingScrollCtrl = ScrollController();
    _initializeData();
  }

  Future<void> _initializeData() async {
    await DataManager.instance.initialize();
    
    // 강제 마이그레이션 실행
    await DataManager.instance.forceMigration();
    
    // 과거 수업 정리 로직 실행 (등원시간만 있는 경우 정상 출석 처리, 기록 없는 경우 무단결석 처리)
    await DataManager.instance.processPastClassesAttendance();
    
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
      // setId를 찾기 위해 해당 학생의 오늘 time block 확인
      final todayIdx = today.weekday - 1;
      final studentTimeBlocks = DataManager.instance.studentTimeBlocks
          .where((block) => 
              block.studentId == record.studentId && 
              block.dayIndex == todayIdx)
          .toList();
      
      for (final block in studentTimeBlocks) {
        if (block.setId != null) {
          // 등원 시간이 있으면 등원 상태로 설정
          if (record.arrivalTime != null) {
            _attendedSetIds.add(block.setId!);
            _attendTimes[block.setId!] = record.arrivalTime!;
          }
          
          // 하원 시간이 있으면 하원 상태로 설정
          if (record.departureTime != null) {
            _leavedSetIds.add(block.setId!);
            _leaveTimes[block.setId!] = record.departureTime!;
          }
        }
      }
    }
  }

  @override
  void dispose() {
    _rotationAnimation.dispose();
    _fabController.dispose();
    _searchController.dispose();
    _leavedScrollCtrl.dispose();
    _attendedScrollCtrl.dispose();
    _waitingScrollCtrl.dispose();
    super.dispose();
  }

  void _toggleSideSheet() {
    print('[SIDE_SHEET] toggle requested. status=${_rotationAnimation.status} value=${_rotationAnimation.value}');
    if (_rotationAnimation.status == AnimationStatus.completed) {
      _rotationAnimation.reverse();
    } else {
      _rotationAnimation.forward();
    }
  }

  Widget _buildContent() {
    print('[DEBUG] _buildContent 진입, _selectedIndex= [38;5;246m$_selectedIndex [0m');
    switch (_selectedIndex) {
      case 0:
        return const HomeScreen();
      case 1:
        return StudentScreen(key: _studentScreenKey);
      case 2:
        return TimetableScreen();
      case 3:
        return const LearningScreen();
      case 4:
        return const ResourcesScreen();
      default:
        return const SizedBox();
    }
  }

  void _showClassRegistrationDialog() {
    if (_studentScreenKey.currentState != null) {
      _studentScreenKey.currentState!.showClassRegistrationDialog();
    }
  }

  void _showStudentRegistrationDialog() {
    if (_studentScreenKey.currentState != null) {
      _studentScreenKey.currentState!.showStudentRegistrationDialog();
    }
  }

  @override
  Widget build(BuildContext context) {
    print('[DEBUG] MainScreen build');
    return Scaffold(
      body: Row(
        children: [
          CustomNavigationRail(
            selectedIndex: _selectedIndex,
            onDestinationSelected: (int index) {
              setState(() {
                _selectedIndex = index;
              });
            },
            rotationAnimation: _rotationAnimation,
            onMenuPressed: _toggleSideSheet,
          ),
          AnimatedBuilder(
            animation: _sideSheetAnimation,
            builder: (context, child) {
              final progress = _sideSheetAnimation.value;
              if (progress <= 0.9) {
                print('[SIDE_SHEET] progress=' + progress.toStringAsFixed(2) + ' (내용 숨김)');
              } else {
                print('[SIDE_SHEET] progress=' + progress.toStringAsFixed(2) + ' (내용 표시 시작)');
              }
              final bool isComplete = _rotationAnimation.status == AnimationStatus.completed && progress >= 1.0;
              if (isComplete != _sideSheetWasComplete) {
                print('[SIDE_SHEET] isComplete changed -> ' + isComplete.toString());
                _sideSheetWasComplete = isComplete;
              }
              final attendanceTargets = isComplete ? getTodayAttendanceTargets() : const <_AttendanceTarget>[];
              // 상태별 분류 (시트가 충분히 열린 뒤에만 실제 데이터 계산)
              final leaved = attendanceTargets.where((t) => _leavedSetIds.contains(t.setId)).toList();
              final attended = attendanceTargets.where((t) => _attendedSetIds.contains(t.setId) && !_leavedSetIds.contains(t.setId)).toList()
                ..sort((a, b) {
                  final ta = _attendTimes[a.setId];
                  final tb = _attendTimes[b.setId];
                  if (ta == null && tb == null) return 0;
                  if (ta == null) return 1; // 시간이 없는 항목은 뒤로
                  if (tb == null) return -1;
                  return ta.compareTo(tb); // 이른 등원 시간이 위로
                });
              final waiting = attendanceTargets.where((t) => !_attendedSetIds.contains(t.setId) && !_leavedSetIds.contains(t.setId)).toList();
              // 출석 전 학생카드: 시작시간별 그룹핑
              final Map<DateTime, List<_AttendanceTarget>> waitingByTime = SplayTreeMap();
              if (isComplete) {
                for (final t in waiting) {
                  waitingByTime.putIfAbsent(t.startTime, () => []).add(t);
                }
              }
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
              final baseRatio = 0.19; // 450 / 1728 ≈ 0.26
              final maxWidth = screenWidth * baseRatio;
              // progress로 내부 콘텐츠는 제어하되, Container 자체는 닫힌 상태에서 0px로 만들어 여백이 생기지 않게 처리
              final containerWidth = progress == 0 ? 0.0 : (maxWidth * progress).clamp(0.0, maxWidth);
              print('[SIDE_SHEET] containerWidth=' + containerWidth.toStringAsFixed(1) + ' / maxWidth=' + maxWidth.toStringAsFixed(1));
              if (isComplete) {
                print('[SIDE_SHEET] lists: leaved=' + leaved.length.toString() + ', attended=' + attended.length.toString() + ', waitingGroups=' + waitingByTime.length.toString());
              }

              // 애니메이션 진행 중에는 내용 위젯을 전혀 생성하지 않고, 빈 컨테이너만 렌더링
              if (!isComplete) {
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeInOut,
                  width: containerWidth,
                  color: const Color(0xFF1F1F1F),
                );
              }

              return AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeInOut,
                width: containerWidth,
                color: const Color(0xFF1F1F1F),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // 내용: 애니메이션 완료 후에만 실제로 구성
                    Column(
                        children: [
                          // 날짜/요일 표시
                          Padding(
                            padding: const EdgeInsets.only(top: 16.0, bottom: 8.0),
                            child: Center(
                              child: Text(
                                _getTodayDateString(),
                                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                          SizedBox(height: 24),
                          // 하원한 학생 리스트(고정 높이, 최대 3줄, 스크롤)
                          Container(
                            constraints: BoxConstraints(
                              minHeight: _cardActualHeight * ((containerWidth / 420.0).clamp(0.78, 1.0)),
                              maxHeight: _cardActualHeight * ((containerWidth / 420.0).clamp(0.78, 1.0)) * _leavedMaxLines + _cardSpacing * ((containerWidth / 420.0).clamp(0.78, 1.0)) * (_leavedMaxLines - 1) + 22 * ((containerWidth / 420.0).clamp(0.78, 1.0)),
                            ),
                            margin: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 0),
                            child: Scrollbar(
                              controller: _leavedScrollCtrl,
                              thumbVisibility: true,
                              child: SingleChildScrollView(
                                controller: _leavedScrollCtrl,
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Wrap(
                                    spacing: _cardSpacing * ((containerWidth / 420.0).clamp(0.78, 1.0)),
                                    runSpacing: _cardSpacing * ((containerWidth / 420.0).clamp(0.78, 1.0)),
                                    verticalDirection: VerticalDirection.down,
                                    children: leaved
                                        .map((t) => _buildAttendanceCard(t, status: 'leaved', key: ValueKey('leaved_${t.setId}'), scale: ((containerWidth / 420.0).clamp(0.78, 1.0))))
                                        .toList(),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          // 파란 네모(출석 박스) - 최대 15줄, 스크롤
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24.0),
                            child: Container(
                              margin: const EdgeInsets.symmetric(vertical: 16),
                              width: double.infinity,
                              decoration: BoxDecoration(
                                color: Color(0xFF1E252E),
                                border: Border.all(color: Color(0xFF1E252E), width: 2),
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
                                      if (attended.isEmpty)
                                        const Center(
                                          child: Text(
                                            '출석',
                                            style: TextStyle(
                                              color: Color(0xFF0F467D),
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
                                              _buildAttendanceCard(attended[i], status: 'attended', key: ValueKey('attended_${attended[i].setId}'), scale: ((containerWidth / 420.0).clamp(0.78, 1.0))),
                                              if (i != attended.length - 1) SizedBox(height: 8 * ((containerWidth / 420.0).clamp(0.78, 1.0))),
                                            ]
                                          ],
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          // 출석 전 학생 리스트(가운데 정렬, 스크롤)
                          if (waitingByTime.isNotEmpty)
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
                                      for (final entry in waitingByTime.entries) ...[
                                        Padding(
                                          padding: const EdgeInsets.only(bottom: 4.0),
                                          child: Center(
                                            child: Text(
                                              _formatTime(entry.key),
                                              style: const TextStyle(color: Colors.white54, fontSize: 14, fontWeight: FontWeight.bold),
                                            ),
                                          ),
                                        ),
                                        Center(
                                          child: Wrap(
                                            alignment: WrapAlignment.center,
                                            spacing: _cardSpacing * ((containerWidth / 420.0).clamp(0.78, 1.0)),
                                            runSpacing: _cardSpacing * ((containerWidth / 420.0).clamp(0.78, 1.0)),
                                            children: entry.value
                                                .map((t) => _buildAttendanceCard(t, status: 'waiting', key: ValueKey('waiting_${t.setId}'), scale: ((containerWidth / 420.0).clamp(0.78, 1.0))))
                                                .toList(),
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
                    // 커버: 완료 전에는 동일 배경색으로 완전히 가림(착시/중간 노출 차단)
                    // 커버는 isComplete 분기에서 빈 컨테이너를 반환하므로 불필요
                  ],
                ),
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
  Widget _buildAttendanceCard(_AttendanceTarget t, {required String status, Key? key, double scale = 1.0}) {
    Color borderColor;
    Color textColor = Colors.white70;
    Widget nameWidget;
    // 밑줄 색상 결정 (보강=파란색, 추가수업=초록색)
    final Color? underlineColor = t.overrideType == OverrideType.replace
        ? const Color(0xFF1976D2)
        : (t.overrideType == OverrideType.add ? const Color(0xFF4CAF50) : null);
    switch (status) {
      case 'attended':
        borderColor = t.classInfo?.color ?? const Color(0xFF0F467D);
        textColor = Colors.white.withOpacity(0.9); // 파란네모 안은 톤을 살짝 낮춘 흰색
        nameWidget = MouseRegion(
          onEnter: (event) {
            final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
            final offset = overlay.globalToLocal(event.position);
            final attendTime = _attendTimes[t.setId];
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
        borderColor = Colors.grey.shade700;
        textColor = Colors.white70;
        nameWidget = MouseRegion(
          onEnter: (event) {
            final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
            final offset = overlay.globalToLocal(event.position);
            // 등원/하원 시간 표시
            final attendTime = _attendTimes[t.setId];
            final leaveTime = _leaveTimes[t.setId];
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
        borderColor = Colors.grey;
        textColor = Colors.white70;
        nameWidget = Text(
          t.student.name,
          style: TextStyle(
            color: textColor,
            fontSize: 16,
            fontWeight: FontWeight.w500,
            decoration: underlineColor != null ? TextDecoration.underline : null,
            decorationColor: underlineColor,
            decorationThickness: underlineColor != null ? 2 : null,
          ),
        );
    }
    // 텍스트 자체의 underline을 사용하여 높이 증가 없이 이름 전체에 밑줄 적용
    // 이름 + 과제 요약 칩들
    final List<Widget> chips = [];
    final hwList = HomeworkStore.instance.items(t.student.id);
    for (final hw in hwList.where((e) => e.status != HomeworkStatus.completed).take(3)) {
      chips.add(const SizedBox(width: 6));
      chips.add(
        MouseRegion(
          onEnter: (e) {
            final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
            final offset = overlay.globalToLocal(e.position);
            _showTooltip(offset, hw.body.isEmpty ? '(내용 없음)' : hw.body);
          },
          onExit: (_) => _removeTooltip(),
          child: GestureDetector(
            onTap: () {
              // 진행 시작
              HomeworkStore.instance.start(t.student.id, hw.id);
              setState(() {});
            },
            onLongPress: () async {
              // 이어가기: 동일 제목/색상으로 내용만 빈 과제 추가
              HomeworkStore.instance.continueAdd(t.student.id, hw.id, body: '');
              setState(() {});
            },
            onSecondaryTap: () {
              // 완료 처리
              HomeworkStore.instance.complete(t.student.id, hw.id);
              setState(() {});
            },
            child: Container(
              height: 22,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(color: const Color(0xFF2A2A2A), borderRadius: BorderRadius.circular(999), border: Border.all(color: hw.color.withOpacity(0.6), width: 1)),
              alignment: Alignment.center,
              child: Text(hw.title, style: const TextStyle(color: Colors.white70, fontSize: 12), overflow: TextOverflow.ellipsis),
            ),
          ),
        ),
      );
    }
    final Widget cardChild = nameWidget; // 이름만 버튼 내부에 표시; 칩은 외부에서 렌더링
    if (status == 'attended') {
      // 출석(파란 네모) 카드: 가로 공간 부족 시 줄바꿈 가능하도록 Wrap 사용
      return Wrap(
        key: key,
        spacing: 0,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          GestureDetector(
            onTap: () async {
              final now = DateTime.now();
              setState(() {
                _leavedSetIds.add(t.setId);
                _leaveTimes[t.setId] = now;
              });
              try {
                final classDateTime = DateTime(now.year, now.month, now.day, t.startHour, t.startMinute);
                final existing = DataManager.instance.getAttendanceRecord(t.student.id, classDateTime);
                if (existing != null) {
                  final updated = existing.copyWith(departureTime: now);
                  await DataManager.instance.updateAttendanceRecord(updated);
                }
                // 하원 시 미완료 과제들을 숙제로 표시
                HomeworkStore.instance.markIncompleteAsHomework(t.student.id);
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
          ),
          const SizedBox(width: 2),
          Tooltip(
            message: '태그 추가',
            child: IconButton(
              onPressed: () => _openClassTagDialog(t),
              icon: const Icon(Icons.circle_outlined, color: Colors.white70),
              iconSize: 16,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
            ),
          ),
          // 과제 추가(빠른 추가)
          const SizedBox(width: 2),
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
              icon: const Icon(Icons.add_rounded, color: Colors.white70),
              iconSize: 16,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
            ),
          ),
          // 이름 옆이 아니라 버튼들 오른쪽에 과제 요약 칩 렌더링
          ..._buildHomeworkChips(t),
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
            } else if (status == 'attended') {
              _leavedSetIds.add(t.setId);
              _leaveTimes[t.setId] = now;
            }
          });
          try {
            final classDateTime = DateTime(now.year, now.month, now.day, t.startHour, t.startMinute);
            if (status == 'waiting') {
              await DataManager.instance.saveOrUpdateAttendance(
                studentId: t.student.id,
                classDateTime: classDateTime,
                classEndTime: classDateTime.add(t.duration),
                className: t.classInfo?.name ?? '수업',
                isPresent: true,
                arrivalTime: now,
              );
            } else if (status == 'attended') {
              final existing = DataManager.instance.getAttendanceRecord(t.student.id, classDateTime);
              if (existing != null) {
                final updated = existing.copyWith(departureTime: now);
                await DataManager.instance.updateAttendanceRecord(updated);
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

  List<Widget> _buildHomeworkChips(_AttendanceTarget t) {
    final List<Widget> chips = [];
    final hwList = HomeworkStore.instance.items(t.student.id);
    for (final hw in hwList.where((e) => e.status != HomeworkStatus.completed).take(3)) {
      if (chips.isNotEmpty) chips.add(const SizedBox(width: 6));
      chips.add(
        MouseRegion(
          onEnter: (e) {
            final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
            final offset = overlay.globalToLocal(e.position);
            _showTooltip(offset, hw.body.isEmpty ? '(내용 없음)' : hw.body);
          },
          onExit: (_) => _removeTooltip(),
          child: GestureDetector(
            onTap: () {
              // 토글: 진행 ↔ 일시정지
              final running = HomeworkStore.instance.runningOf(t.student.id);
              if (running != null && running.id == hw.id) {
                HomeworkStore.instance.pause(t.student.id, hw.id);
              } else {
                HomeworkStore.instance.start(t.student.id, hw.id);
              }
              setState(() {});
            },
            onLongPress: () async {
              // 이어가기 다이얼로그 표시
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
              // 완료 처리
              HomeworkStore.instance.complete(t.student.id, hw.id);
              setState(() {});
            },
            child: Builder(builder: (context) {
              final style = TextStyle(
                color: (HomeworkStore.instance.runningOf(t.student.id)?.id == hw.id)
                    ? Colors.white
                    : Colors.white70,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              );
              // 긴 제목도 잘리지 않도록 실제 텍스트 폭을 모두 반영
              final painter = TextPainter(
                text: TextSpan(text: hw.title, style: style),
                maxLines: 1,
                textDirection: TextDirection.ltr,
              )..layout(minWidth: 0, maxWidth: double.infinity);
              const double leftPad = 10;
              const double rightPad = 12; // 오른쪽 여백 살짝 증가로 시각 중심 보정
              final double width = painter.width + leftPad + rightPad;
              return SizedBox(
                width: width.clamp(40.0, 560.0),
                child: Container(
                  height: 36,
                  padding: const EdgeInsets.fromLTRB(leftPad, 0, rightPad, 0),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFF2A2A2A),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: (HomeworkStore.instance.runningOf(t.student.id)?.id == hw.id)
                          ? hw.color.withOpacity(0.9)
                          : Colors.white24,
                      width: (HomeworkStore.instance.runningOf(t.student.id)?.id == hw.id) ? 2 : 1,
                    ),
                  ),
                  child: Text(
                    hw.title,
                    style: style,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.visible, // 줄바꿈 방지
                  ),
                ),
              );
            }),
          ),
        ),
      );
    }
    return chips;
  }
}

// 출석 대상 학생 정보 구조체
class _AttendanceTarget {
  final String setId;
  final Student student;
  final ClassInfo? classInfo;
  final int startHour;
  final int startMinute;
  final Duration duration;
  final OverrideType? overrideType; // null이면 일반 수업, replace=보강(파란줄), add=추가수업(초록줄)
  _AttendanceTarget({required this.setId, required this.student, required this.classInfo, required this.startHour, required this.startMinute, required this.duration, this.overrideType});

  DateTime get startTime => DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day, startHour, startMinute);
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

// 태그 이벤트: 태그 + 적용 시각
class _ClassTagEvent {
  final _ClassTag tag;
  final DateTime timestamp;
  final String? note; // '기록' 등 메모성 태그용 텍스트
  const _ClassTagEvent({required this.tag, required this.timestamp, this.note});
}

extension on _MainScreenState {
  Future<void> _openClassTagDialog(_AttendanceTarget target) async {
    final List<_ClassTagEvent> initialApplied = List<_ClassTagEvent>.from(_classTagEventsBySetId[target.setId] ?? const []);
    List<_ClassTagEvent> workingApplied = List<_ClassTagEvent>.from(initialApplied);

    List<_ClassTag> workingAvailable = List<_ClassTag>.from(_availableClassTags);

    _ClassTag? newTag;

    List<_ClassTagEvent>? result = await showDialog<List<_ClassTagEvent>>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            Future<void> _handleTagPressed(_ClassTag tag) async {
              if (tag.name == '기록') {
                final note = await _openRecordNoteDialog(ctx);
                if (note == null || note.trim().isEmpty) return;
                setLocal(() {
                  workingApplied.add(_ClassTagEvent(tag: tag, timestamp: DateTime.now(), note: note.trim()));
                });
              } else {
                setLocal(() {
                  workingApplied.add(_ClassTagEvent(tag: tag, timestamp: DateTime.now()));
                });
              }
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
              backgroundColor: const Color(0xFF1F1F1F),
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
                  onPressed: () => Navigator.of(ctx).pop(null),
                  child: const Text('취소', style: TextStyle(color: Colors.white70)),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.of(ctx).pop(workingApplied),
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1976D2), foregroundColor: Colors.white),
                  child: const Text('저장'),
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
      TagStore.instance.setEventsForSet(target.setId, events);
    }
  }

  Future<_ClassTag?> _createNewClassTag(BuildContext context) async {
    final TextEditingController nameController = TextEditingController();
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
              backgroundColor: const Color(0xFF1F1F1F),
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
    final TextEditingController controller = TextEditingController();
    return showDialog<String?>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1F1F1F),
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