import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/navigation_rail.dart';
import '../widgets/student_registration_dialog.dart';
import '../services/data_manager.dart';
import 'student/student_screen.dart';
import 'timetable/timetable_screen.dart';
import 'settings/settings_screen.dart';
import '../models/student.dart';
import '../models/group_info.dart';
import '../models/student_view_type.dart';
import '../widgets/main_fab.dart';
import '../models/class_info.dart';
import '../models/student_time_block.dart';
import 'dart:collection';
import '../models/education_level.dart';

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
    final result = <_AttendanceTarget>[];
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
        result.add(_AttendanceTarget(
          setId: entry.key,
          student: student.student,
          classInfo: classInfo,
          startTime: block.startTime,
        ));
      }
    }
    // 시작시간 기준 정렬
    result.sort((a, b) => a.startTime.compareTo(b.startTime));
    return result;
  }

  // 출석/하원 시간 기록용
  final Map<String, DateTime> _attendTimes = {};
  final Map<String, DateTime> _leaveTimes = {};

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
    _rotationAnimation = AnimationController(
      duration: const Duration(milliseconds: 350),
      vsync: this,
    );
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
    _initializeData();
  }

  Future<void> _initializeData() async {
    await DataManager.instance.initialize();
    setState(() {
      _groups.clear();
      _groups.addAll(DataManager.instance.groups);
      _students.clear();
      _students.addAll(DataManager.instance.students.map((s) => s.student));
    });
  }

  @override
  void dispose() {
    _rotationAnimation.dispose();
    _fabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _toggleSideSheet() {
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
        return const Center(child: Text('홈', style: TextStyle(color: Colors.white)));
      case 1:
        return StudentScreen(key: _studentScreenKey);
      case 2:
        return TimetableScreen();
      case 3:
        return const Center(child: Text('학습', style: TextStyle(color: Colors.white, fontSize: 24)));
      case 4:
        return const Center(child: Text('자료', style: TextStyle(color: Colors.white, fontSize: 24)));
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
              final attendanceTargets = getTodayAttendanceTargets();
              // 상태별 분류
              final leaved = attendanceTargets.where((t) => _leavedSetIds.contains(t.setId)).toList();
              final attended = attendanceTargets.where((t) => _attendedSetIds.contains(t.setId) && !_leavedSetIds.contains(t.setId)).toList();
              final waiting = attendanceTargets.where((t) => !_attendedSetIds.contains(t.setId) && !_leavedSetIds.contains(t.setId)).toList();

              // 출석 전 학생카드: 시작시간별 그룹핑
              final Map<DateTime, List<_AttendanceTarget>> waitingByTime = SplayTreeMap();
              for (final t in waiting) {
                waitingByTime.putIfAbsent(t.startTime, () => []).add(t);
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

              return Container(
                width: 450 * _sideSheetAnimation.value,
                color: const Color(0xFF1F1F1F),
                child: _sideSheetAnimation.value > 0
                    ? Column(
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
                          // 하원한 학생 리스트(고정 높이, 최대 3줄, 스크롤)
                          Container(
                            constraints: BoxConstraints(
                              minHeight: _cardActualHeight,
                              maxHeight: _cardActualHeight * _leavedMaxLines + _cardSpacing * (_leavedMaxLines - 1),
                            ),
                            margin: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 0),
                            child: Scrollbar(
                              thumbVisibility: true,
                              child: SingleChildScrollView(
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Wrap(
                                    spacing: _cardSpacing,
                                    runSpacing: _cardSpacing,
                                    verticalDirection: VerticalDirection.down,
                                    children: leaved
                                        .map((t) => AnimatedSwitcher(
                                              duration: const Duration(milliseconds: 350),
                                              switchInCurve: Curves.elasticOut,
                                              switchOutCurve: Curves.easeOut,
                                              child: _buildAttendanceCard(t, status: 'leaved', key: ValueKey('leaved_${t.setId}')),
                                            ))
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
                                minHeight: _cardActualHeight,
                                maxHeight: _cardActualHeight * _attendedMaxLines + _attendedRunSpacing * (_attendedMaxLines - 1),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 24.0, horizontal: 16.0),
                              child: Scrollbar(
                                thumbVisibility: true,
                                child: SingleChildScrollView(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      if (attended.isEmpty)
                                        Center(
                                          child: Text(
                                            DataManager.instance.academySettings.name.isNotEmpty
                                                ? DataManager.instance.academySettings.name
                                                : '학원명',
                                            style: const TextStyle(
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
                                              // status는 'attended'로 고정, 파란네모 안은 툴팁 없음
                                              _buildAttendanceCard(attended[i], status: 'attended', key: ValueKey('attended_${attended[i].setId}')),
                                              if (i != attended.length - 1) SizedBox(height: 8),
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
                                  thumbVisibility: true,
                                  child: ListView(
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
                                            spacing: _cardSpacing,
                                            runSpacing: _cardSpacing,
                                            children: entry.value
                                                .map((t) => GestureDetector(
                                                      onTap: () {
                                                        setState(() {
                                                          _attendedSetIds.add(t.setId);
                                                          _attendTimes[t.setId] = DateTime.now();
                                                        });
                                                      },
                                                      child: MouseRegion(
                                                        onEnter: (event) {
                                                          final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
                                                          final offset = overlay.globalToLocal(event.position);
                                                          String tooltip = '${t.student.school}\n${_MainScreenState._educationLevelToKorean(t.student.educationLevel)} / ${t.student.grade}학년';
                                                          _showTooltip(offset, tooltip);
                                                        },
                                                        onExit: (_) => _removeTooltip(),
                                                        child: AnimatedContainer(
                                                          duration: const Duration(milliseconds: 200),
                                                          margin: EdgeInsets.zero,
                                                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                                                          decoration: BoxDecoration(
                                                            color: Colors.transparent,
                                                            border: Border.all(color: Colors.grey, width: 2),
                                                            borderRadius: BorderRadius.circular(25),
                                                          ),
                                                          child: Text(
                                                            t.student.name,
                                                            style: const TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.w500),
                                                          ),
                                                        ),
                                                      ),
                                                    ))
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
                      )
                    : const SizedBox(),
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
      floatingActionButton: MainFab(),
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
  Widget _buildAttendanceCard(_AttendanceTarget t, {required String status, Key? key}) {
    Color borderColor;
    Color textColor = Colors.white70;
    Widget child;
    switch (status) {
      case 'attended':
        borderColor = t.classInfo?.color ?? const Color(0xFF0F467D);
        textColor = Colors.white; // 파란네모 안은 흰색
        child = Text(
          t.student.name,
          style: TextStyle(
            color: textColor,
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
        );
        break;
      case 'leaved':
        borderColor = Colors.grey.shade700;
        textColor = Colors.white70;
        child = MouseRegion(
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
            style: TextStyle(color: textColor, fontSize: 16, fontWeight: FontWeight.w500),
          ),
        );
        break;
      default:
        borderColor = Colors.grey;
        textColor = Colors.white70;
        child = Text(
          t.student.name,
          style: TextStyle(color: textColor, fontSize: 16, fontWeight: FontWeight.w500),
        );
    }
    return GestureDetector(
      key: key,
      onTap: () {
        setState(() {
          if (status == 'waiting') {
            _attendedSetIds.add(t.setId);
            _attendTimes[t.setId] = DateTime.now();
          } else if (status == 'attended') {
            _leavedSetIds.add(t.setId);
            _leaveTimes[t.setId] = DateTime.now();
          }
        });
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
        child: child,
      ),
    );
  }
}

// 출석 대상 학생 정보 구조체
class _AttendanceTarget {
  final String setId;
  final Student student;
  final ClassInfo? classInfo;
  final DateTime startTime;
  _AttendanceTarget({required this.setId, required this.student, required this.classInfo, required this.startTime});
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