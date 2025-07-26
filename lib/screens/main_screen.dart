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
  void _showTooltip(BuildContext context, Offset position, String text) {
    _removeTooltip();
    final overlay = Overlay.of(context);
    _tooltipOverlay = OverlayEntry(
      builder: (context) => Positioned(
        left: position.dx + 12,
        top: position.dy + 12,
        child: Material(
          color: Colors.transparent,
          child: Container(
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
  }
  void _removeTooltip() {
    _tooltipOverlay?.remove();
    _tooltipOverlay = null;
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
                          // 위쪽(하원 리스트)
                          Flexible(
                            flex: 2,
                            child: Padding(
                              padding: const EdgeInsets.only(top: 24.0, left: 24.0, right: 24.0, bottom: 8.0),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: ClipRect(
                                  child: _ellipsisWrap(
                                    leaved
                                        .map((t) => AnimatedSwitcher(
                                              duration: const Duration(milliseconds: 350),
                                              switchInCurve: Curves.elasticOut,
                                              switchOutCurve: Curves.easeOut,
                                              child: _buildAttendanceCard(t, status: 'leaved', key: ValueKey('leaved_${t.setId}')),
                                            ))
                                        .toList(),
                                    maxLines: 2,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          // 파란 네모(출석 박스) - 항상 가운데
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24.0),
                            child: Container(
                              margin: const EdgeInsets.symmetric(vertical: 16),
                              width: double.infinity,
                              decoration: BoxDecoration(
                                color: Colors.transparent,
                                border: Border.all(color: Color(0xFF0F467D), width: 2),
                                borderRadius: BorderRadius.circular(18),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 24.0, horizontal: 16.0),
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
                                      children: attended
                                          .map((t) => AnimatedSwitcher(
                                                duration: const Duration(milliseconds: 350),
                                                switchInCurve: Curves.elasticOut,
                                                switchOutCurve: Curves.easeOut,
                                                child: _buildAttendanceCard(t, status: 'attended', key: ValueKey('attended_${t.setId}')),
                                              ))
                                          .toList(),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          // 아래쪽(출석 전 학생 리스트)
                          Flexible(
                            flex: 2,
                            child: Padding(
                              padding: const EdgeInsets.only(top: 0, left: 24.0, right: 24.0, bottom: 24.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  for (final entry in waitingByTime.entries) ...[
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 4.0),
                                      child: Text(
                                        _formatTime(entry.key),
                                        style: const TextStyle(color: Colors.white54, fontSize: 14, fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                    ClipRect(
                                      child: _ellipsisWrap(
                                        entry.value
                                            .map((t) => AnimatedSwitcher(
                                                  duration: const Duration(milliseconds: 350),
                                                  switchInCurve: Curves.elasticOut,
                                                  switchOutCurve: Curves.easeOut,
                                                  child: _buildAttendanceCard(t, status: 'waiting', key: ValueKey('waiting_${t.setId}')),
                                                ))
                                            .toList(),
                                        maxLines: 2,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                  ],
                                ],
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

  // 출석/하원 카드 위젯
  Widget _buildAttendanceCard(_AttendanceTarget t, {required String status, Key? key}) {
    Color borderColor;
    Color textColor = Colors.white70;
    Widget child;
    switch (status) {
      case 'attended':
        borderColor = t.classInfo?.color ?? const Color(0xFF0F467D);
        textColor = Colors.white70; // 항상 회색
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
        child = _TooltipHoverArea(
          main: t.student.name,
          tooltip: '등원: ${_attendTimes[t.setId] != null ? _formatTime(_attendTimes[t.setId]!) : '-'}\n하원: ${_leaveTimes[t.setId] != null ? _formatTime(_leaveTimes[t.setId]!) : '-'}',
          showTooltip: _showTooltip,
          hideTooltip: _removeTooltip,
          textColor: textColor,
        );
        break;
      default:
        borderColor = Colors.grey;
        textColor = Colors.white70;
        child = _TooltipHoverArea(
          main: t.student.name,
          tooltip: '${t.student.school}\n${t.student.educationLevel.name} / ${t.student.grade}학년',
          showTooltip: _showTooltip,
          hideTooltip: _removeTooltip,
          textColor: textColor,
        );
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 350),
      switchInCurve: Curves.elasticOut,
      switchOutCurve: Curves.easeOut,
      child: GestureDetector(
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
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.transparent,
            border: Border.all(color: borderColor, width: 2),
            borderRadius: BorderRadius.circular(30),
          ),
          child: child,
        ),
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