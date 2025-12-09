import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/attendance_record.dart';
import '../../models/payment_record.dart';
import '../../models/session_override.dart';
import '../../models/student.dart';
import '../../services/data_manager.dart';
import 'components/attendance_indicator.dart';
import 'components/student_course_history_tab.dart';

class StudentCourseDetailScreen extends StatefulWidget {
  final StudentWithInfo studentWithInfo;
  const StudentCourseDetailScreen({super.key, required this.studentWithInfo});

  @override
  State<StudentCourseDetailScreen> createState() => _StudentCourseDetailScreenState();
}

class _StudentCourseDetailScreenState extends State<StudentCourseDetailScreen> {
  DateTime _currentDate = DateTime.now();
  int _selectedTabIndex = 0; // 0: Payment, 1: Attendance, 2: History
  final ScrollController _attendanceScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
  }

  Future<void> _openAttendanceEditDialog(AttendanceRecord record) async {
    final TextEditingController arrivalController = TextEditingController(text: _hhmm(record.arrivalTime));
    final TextEditingController departureController = TextEditingController(text: _hhmm(record.departureTime));

    TimeOfDay? _parse(String? text) {
      if (text == null || text.isEmpty || text == '--:--') return null;
      final parts = text.split(':');
      if (parts.length != 2) return null;
      final h = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      if (h == null || m == null) return null;
      return TimeOfDay(hour: h, minute: m);
    }

    DateTime _combine(DateTime base, TimeOfDay tod) =>
        DateTime(base.year, base.month, base.day, tod.hour, tod.minute);

    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF0B1112),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF223131)),
          ),
          titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
          contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          title: const Text(
            '출석 수정',
            style: TextStyle(color: Color(0xFFEAF2F2), fontSize: 20, fontWeight: FontWeight.bold),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Divider(color: Color(0xFF223131), height: 1),
              const SizedBox(height: 16),
              _TimeField(label: '등원 시간', controller: arrivalController),
              const SizedBox(height: 12),
              _TimeField(label: '하원 시간', controller: departureController),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await DataManager.instance.deleteAttendanceRecord(record.id!);
                Navigator.of(context).pop(true);
              },
              child: const Text('삭제', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('취소', style: TextStyle(color: Colors.white70)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1B6B63),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () async {
                final arr = _parse(arrivalController.text);
                final dep = _parse(departureController.text);
                DateTime? newArrival = arr != null ? _combine(record.classDateTime, arr) : null;
                DateTime? newDeparture = dep != null ? _combine(record.classDateTime, dep) : null;
                await DataManager.instance.updateAttendanceRecord(
                  record.copyWith(
                    arrivalTime: newArrival,
                    departureTime: newDeparture,
                    updatedAt: DateTime.now(),
                  ),
                );
                if (mounted) setState(() {});
                if (context.mounted) Navigator.of(context).pop(true);
              },
              child: const Text('저장', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );

    if (result == true && mounted) setState(() {});
  }

  void _updateMonth(int delta) {
    setState(() {
      _currentDate = DateTime(_currentDate.year, _currentDate.month + delta);
    });
    _scrollToMonth(_currentDate);
  }

  void _scrollToMonth(DateTime targetMonth) {
    // Wait for build to complete so we have the updated list (though list content is static, just offset)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_attendanceScrollController.hasClients) return;

      final studentId = widget.studentWithInfo.student.id;
      final records = DataManager.instance.getAttendanceRecordsForStudent(studentId)
        ..sort((a, b) => b.classDateTime.compareTo(a.classDateTime));
      
      // Find the index of the first record that belongs to the target month (or older if none in that month)
      // Since it's sorted descending (latest first), the first record matching year/month is the latest in that month.
      int targetIndex = records.indexWhere((r) => 
        r.classDateTime.year == targetMonth.year && r.classDateTime.month == targetMonth.month
      );

      // If no record in that month, find the first record *before* that month (older)
      if (targetIndex == -1) {
         targetIndex = records.indexWhere((r) => r.classDateTime.isBefore(DateTime(targetMonth.year, targetMonth.month)));
      }
      
      // If still -1 (meaning all records are in future relative to targetMonth?), scroll to 0
      if (targetIndex == -1) targetIndex = 0;

      // Calculate offset. Using itemExtent 56.0
      // We use ListView.builder with explicit itemExtent for performance and precise jumping
      const double itemExtent = 56.0;
      final double offset = targetIndex * itemExtent;

      _attendanceScrollController.jumpTo(offset);
    });
  }

  @override
  void dispose() {
    _attendanceScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final student = widget.studentWithInfo.student;
    return Scaffold(
      backgroundColor: const Color(0xFF0B1112),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(context, student.name),
              const SizedBox(height: 16),
              Expanded(
                child: Align(
                  alignment: Alignment.topCenter,
                child: SingleChildScrollView(
                    padding: const EdgeInsets.only(bottom: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1180),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                layoutBuilder: (Widget? currentChild, List<Widget> previousChildren) {
                  return Stack(
                    alignment: Alignment.topCenter,
                    children: <Widget>[
                      ...previousChildren,
                      if (currentChild != null) currentChild,
                    ],
                  );
                },
                child: _buildActiveTabContent(),
              ),
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

  Widget _buildActiveTabContent() {
    switch (_selectedTabIndex) {
      case 0:
        return KeyedSubtree(
          key: const ValueKey('payment'),
          child: _buildPaymentSection(),
        );
      case 1:
        return KeyedSubtree(
          key: const ValueKey('attendance'),
          child: _buildAttendanceSection(),
        );
      default:
        return KeyedSubtree(
          key: const ValueKey('history'),
          child: StudentCourseHistoryTab(studentWithInfo: widget.studentWithInfo),
        );
    }
  }

  Widget _buildHeader(BuildContext context, String name) {
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: const Color(0xFF151C21),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF223131)),
          ),
          child: IconButton(
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.arrow_back, color: Colors.white, size: 20),
            onPressed: () => Navigator.of(context).pop(),
            tooltip: '뒤로',
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Stack(
            alignment: Alignment.center,
          children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(right: 360),
                  child: Text(
              name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
            ),
            ),
              ),
              _buildTabSelector(),
          ],
          ),
        ),
      ],
    );
  }

  Widget _buildTabSelector() {
    const List<String> tabs = ['수강료', '출결', '수업 기록'];
    return SizedBox(
      width: 320,
      child: Container(
        height: 40,
        decoration: BoxDecoration(
          color: const Color(0xFF151C21),
          borderRadius: BorderRadius.circular(20),
        ),
        padding: const EdgeInsets.all(4),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final double tabWidth = (constraints.maxWidth - 8) / tabs.length;
            return Stack(
              children: [
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutCubic,
                  left: _selectedTabIndex * tabWidth,
                  top: 0,
                  bottom: 0,
                  width: tabWidth,
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF1B6B63),
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.2),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                  ),
                ),
                Row(
                  children: tabs.asMap().entries.map((entry) {
                    final index = entry.key;
                    final label = entry.value;
                    final isSelected = _selectedTabIndex == index;
                    return GestureDetector(
                      onTap: () => setState(() => _selectedTabIndex = index),
                      behavior: HitTestBehavior.translucent,
                      child: SizedBox(
                        width: tabWidth,
                        child: Center(
                          child: AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 200),
                            style: TextStyle(
                              color: isSelected ? Colors.white : const Color(0xFF7E8A8A),
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                            child: Text(label),
              ),
            ),
          ),
                    );
                  }).toList(),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildAttendanceSection() {
    const double panelHeight = 720;
    final monthLabel = '${_currentDate.year}년 ${_currentDate.month}월';
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0B1112),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('출결 현황', style: TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w700)),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Flexible(
                flex: 6,
                child: SizedBox(
                  height: panelHeight + 48,
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF0B1112),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFF223131)),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton(
                              onPressed: () => _updateMonth(-1),
                              icon: const Icon(Icons.chevron_left, color: Colors.white70),
                            ),
                            const SizedBox(width: 12),
                        Text(
                              monthLabel,
                              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(width: 12),
                            IconButton(
                              onPressed: () => _updateMonth(1),
                              icon: const Icon(Icons.chevron_right, color: Colors.white70),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Expanded(
                          child: Center(
                            child: AspectRatio(
                              aspectRatio: 1,
                              child: _buildCalendarGrid(),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _buildCalendarLegend(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 24),
              Flexible(
                flex: 4,
                child: SizedBox(
                  height: panelHeight + 48,
                  child: _buildAttendanceListPanel(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCalendarGrid() {
    final daysInMonth = DateUtils.getDaysInMonth(_currentDate.year, _currentDate.month);
    final firstDayOfMonth = DateTime(_currentDate.year, _currentDate.month, 1);
    final weekdayOfFirstDay = firstDayOfMonth.weekday;
    final today = DateTime.now();
    final headers = ['월', '화', '수', '목', '금', '토', '일'];

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: headers
                .map((day) => Expanded(
                      child: Center(
                        child: Text(day, style: const TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.w600)),
                      ),
                    ))
                .toList(),
          ),
        ),
        Expanded(
          child: GridView.builder(
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 7),
            itemCount: daysInMonth + weekdayOfFirstDay - 1,
            itemBuilder: (context, index) {
              if (index < weekdayOfFirstDay - 1) return const SizedBox.shrink();
              final dayNumber = index - (weekdayOfFirstDay - 1) + 1;
              final date = DateTime(_currentDate.year, _currentDate.month, dayNumber);
              final isToday = DateUtils.isSameDay(date, today);
              final studentId = widget.studentWithInfo.student.id;

              const double indicatorWidth = 45.0; // 고정 너비로 축소
              return Container(
                margin: const EdgeInsets.all(6),
                decoration: isToday
                    ? BoxDecoration(
                        border: Border.all(color: const Color(0xFF1B6B63), width: 3),
                        borderRadius: BorderRadius.circular(12),
                      )
                    : null,
                child: Stack(
                  children: [
                    Center(
                      child: Text(
                        '$dayNumber',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: isToday ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: 8,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: AttendanceIndicator(
                          studentId: studentId,
                          date: date,
                          width: indicatorWidth,
                          thickness: 6,
                        ),
                      ),
                    ),
                    Positioned(
                      top: 8,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: _AddOverrideDot(studentId: studentId, date: date),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildCalendarLegend() {
    const Color _colorPresent = Color(0xFF33A373); // 정상
    const Color _colorLate = Color(0xFFF2B45B);    // 지각
    const Color _colorAbsent = Color(0xFFE57373);  // 결석
    const Color _colorOverride = Color(0xFF5DD6FF); // 보강/추가수업

    final List<_LegendEntry> legends = [
      const _LegendEntry('출석', _colorPresent),
      const _LegendEntry('지각', _colorLate),
      const _LegendEntry('결석', _colorAbsent),
      const _LegendEntry('보강, 추가수업', _colorOverride),
    ];

    return Align(
      alignment: Alignment.center,
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 24,
        runSpacing: 10,
        children: legends
            .map(
              (entry) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(color: entry.color, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    entry.label,
                    style: const TextStyle(color: Colors.white70, fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            )
            .toList(),
      ),
    );
  }

  Widget _buildAttendanceListPanel() {
    final studentId = widget.studentWithInfo.student.id;
    final uniqueRecords = _uniqueAttendanceRecords(studentId);

    if (uniqueRecords.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: const Color(0xFF151C21),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF223131)),
        ),
        child: Center(
          child: Text(
            '출석 기록이 없습니다.',
            style: TextStyle(color: Colors.white.withOpacity(0.5)),
          ),
        ),
      );
    }

    final int total = uniqueRecords.length;
    int lateCount = 0;
    int absentCount = 0;
    for (final record in uniqueRecords) {
      if (_isAbsent(record)) {
        absentCount++;
      } else if (_isLate(record)) {
        lateCount++;
      }
    }
    double _rate(int count) => total == 0 ? 0 : (count / total * 100);
    final double lateRate = _rate(lateCount);
    final double absentRate = _rate(absentCount);

    Widget metric(String label, double rate, Color color) {
      return Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withOpacity(0.4)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(color: color.withOpacity(0.9), fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text('${rate.toStringAsFixed(1)}%',
                  style: TextStyle(color: color, fontSize: 20, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF151C21),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF223131)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                metric('지각률', lateRate, const Color(0xFFF2B45B)),
                const SizedBox(width: 12),
                metric('결석률', absentRate, const Color(0xFFE57373)),
              ],
            ),
          ),
          const Divider(color: Color(0xFF223131), height: 1),
          Expanded(
            child: Scrollbar(
              controller: _attendanceScrollController,
              thumbVisibility: true,
              child: ListView.builder(
                controller: _attendanceScrollController,
                padding: EdgeInsets.zero,
                itemCount: uniqueRecords.length,
                itemExtent: 82.0,
                itemBuilder: (context, index) {
                  final record = uniqueRecords[index];
                  final dateLabel = DateFormat('MM.dd (E)', 'ko').format(record.classDateTime);
                  final registrationDate = widget.studentWithInfo.basicInfo.registrationDate;
                  int? cycle;
                  int? sessionOrder;
                  if (registrationDate != null) {
                    final regDate = DateTime(registrationDate.year, registrationDate.month, registrationDate.day);
                    cycle = _calculateCycleNumber(regDate, record.classDateTime);
                    final sameCycle = uniqueRecords
                        .where((r) => _calculateCycleNumber(regDate, r.classDateTime) == cycle)
                        .toList()
                      ..sort((a, b) => a.classDateTime.compareTo(b.classDateTime));
                    sessionOrder = sameCycle.indexOf(record) + 1;
                  }

                  // 수업명 및 보강/추가수업 배지
                  String className = '';
                  String? overrideBadge;
                  final overrides = DataManager.instance.sessionOverrides;
                  bool sameMinute(DateTime a, DateTime b) =>
                      a.year == b.year && a.month == b.month && a.day == b.day && a.hour == b.hour && a.minute == b.minute;
                  SessionOverride? matchedOverride;
                  for (final ov in overrides) {
                    final repl = ov.replacementClassDateTime;
                    if (repl == null) continue;
                    if (ov.studentId != record.studentId) continue;
                    if (sameMinute(repl, record.classDateTime)) {
                      overrideBadge = ov.overrideType == OverrideType.add ? '추가수업' : '보강';
                      matchedOverride = ov;
                      break;
                    }
                  }
                  className = _resolveDisplayClassName(record, matchedOverride);

                  final String? tooltipMessage = (matchedOverride?.originalClassDateTime != null)
                      ? '원본 : ${DateFormat('MM.dd (E)', 'ko').format(matchedOverride!.originalClassDateTime!)} '
                          '${_hhmm(matchedOverride!.originalClassDateTime)} ~ ${_hhmm(matchedOverride!.originalClassDateTime!.add(Duration(minutes: matchedOverride!.durationMinutes ?? 60)))}'
                      : null;

                  String statusText;
                  Color statusColor;
                  if (!record.isPresent) {
                    statusText = '결석';
                    statusColor = const Color(0xFFE57373);
                  } else {
                    final lateThreshold = record.classDateTime.add(const Duration(minutes: 10));
                    if (record.arrivalTime != null && record.arrivalTime!.isAfter(lateThreshold)) {
                      statusText = '지각';
                      statusColor = const Color(0xFFF2B45B);
                    } else {
                      statusText = '출석';
                      statusColor = const Color(0xFF33A373);
                    }
                  }

                  Widget card = Container(
                    decoration: const BoxDecoration(
                      border: Border(bottom: BorderSide(color: Color(0xFF223131), width: 1)),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Row(
                                children: [
                                  Text(
                                    cycle != null && sessionOrder != null ? '${cycle}회차 ${sessionOrder}회' : '',
                                    style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700),
                                  ),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Flexible(
                                          child: Text(
                                            className,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w600),
                                          ),
                                        ),
                                        if (overrideBadge != null) ...[
                                          const SizedBox(width: 6),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF5DD6FF).withOpacity(0.22),
                                              borderRadius: BorderRadius.circular(999),
                                              border: Border.all(color: const Color(0xFF5DD6FF).withOpacity(0.65)),
                                            ),
                                            child: Text(
                                              overrideBadge!,
                                              style: const TextStyle(color: Color(0xFF5DD6FF), fontSize: 11.5, fontWeight: FontWeight.w800),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${_hhmm(record.classDateTime)} ~ ${_hhmm(record.classEndTime)}',
                              textAlign: TextAlign.right,
                              style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w700),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Text(
                              dateLabel,
                              style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                            ),
                            const Spacer(),
                            if (record.isPresent) ...[
                              Text(
                                '${_hhmm(record.arrivalTime)} ~ ${_hhmm(record.departureTime)}',
                                style: const TextStyle(color: Colors.white70, fontSize: 14),
                              ),
                              const SizedBox(width: 10),
                            ],
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: statusColor.withOpacity(0.18),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: statusColor.withOpacity(0.5)),
                              ),
                              child: Text(
                                statusText,
                                style: TextStyle(color: statusColor, fontSize: 13, fontWeight: FontWeight.w700),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );

                  if (tooltipMessage != null && tooltipMessage.isNotEmpty) {
                    card = Tooltip(
                      message: tooltipMessage,
                      waitDuration: const Duration(milliseconds: 150),
                      decoration: BoxDecoration(
                        color: const Color(0xFF11181C),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF2B3A42)),
                      ),
                      textStyle: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                      child: card,
                    );
                  }

                  return InkWell(
                    onTap: () => _openAttendanceEditDialog(record),
                    child: card,
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPaymentSection() {
    final student = widget.studentWithInfo.student;
    final payments = DataManager.instance.getPaymentRecordsForStudent(student.id)
      ..sort((a, b) => b.dueDate.compareTo(a.dueDate));
    final DateTime now = DateTime.now();
    final DateTime nextMonthStart = DateTime(now.year, now.month + 1, 1);

    PaymentRecord upcoming;
    if (payments.isNotEmpty) {
      upcoming = payments.lastWhere(
        (record) => record.paidDate == null && !record.dueDate.isBefore(nextMonthStart),
        orElse: () {
          return payments.firstWhere(
      (record) => record.paidDate == null,
            orElse: () => payments.first,
          );
        },
      );
    } else {
      upcoming = PaymentRecord(studentId: student.id, cycle: 1, dueDate: nextMonthStart);
    }

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0B1112),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('납부 내역', style: TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w700)),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Flexible(
                flex: 5,
                child: _buildYearlyOverviewCard(),
              ),
              const SizedBox(width: 24),
              Flexible(
                flex: 4,
                child: Column(
                  children: [
                    _buildUpcomingPaymentCard(upcoming),
                    const SizedBox(height: 16),
                    _buildPaymentHistoryList(
                      upcomingRecord: upcoming,
                      maxHeight: 420,
              ),
            ],
          ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildUpcomingPaymentCard(PaymentRecord upcoming) {
    return Container(
      padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
        color: const Color(0xFF151C21),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF223131)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '다음 납부 예정일',
            style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 14, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
            DateFormat('yyyy.MM.dd').format(upcoming.dueDate),
                  style: const TextStyle(color: Color(0xFF90CAF9), fontSize: 24, fontWeight: FontWeight.w800),
                ),
                if (upcoming.paidDate != null)
                  Padding(
              padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '납부 완료 (${DateFormat('MM.dd').format(upcoming.paidDate!)})',
                style: const TextStyle(color: Colors.white60, fontSize: 14),
              ),
            ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => _showPaymentDatePicker(upcoming, markAsPaid: false),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF9FB3B3),
                side: const BorderSide(color: Color(0xFF4D5A5A)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
                  child: const Text('예정일 수정'),
            ),
                ),
              ],
            ),
    );
  }

  Widget _buildYearlyOverviewCard() {
    final registrationDate = widget.studentWithInfo.basicInfo.registrationDate;
    final studentId = widget.studentWithInfo.student.id;
    final int year = DateTime.now().year;
    final List<DateTime> months = List.generate(12, (index) => DateTime(year, index + 1, 1));

    if (registrationDate == null) {
    return Container(
      decoration: BoxDecoration(
          color: const Color(0xFF151C21),
          borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF223131)),
      ),
        child: const Center(
          child: Text('등록일 정보가 없습니다.', style: TextStyle(color: Colors.white60)),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF151C21),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(12),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1,
        ),
        itemCount: months.length,
        itemBuilder: (context, index) {
          final month = months[index];
          final status = _resolveMonthlyStatus(studentId, registrationDate, month);
          final Color ringColor = status.dimmed ? status.color.withOpacity(0.55) : status.color;
          final Color textColor = status.dimmed ? Colors.white60 : Colors.white;

    return Container(
      decoration: BoxDecoration(
              color: const Color(0xFF10171B),
              borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF223131)),
      ),
            child: Center(
      child: Column(
                mainAxisSize: MainAxisSize.min,
        children: [
                  Container(
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: ringColor, width: 3),
                    ),
                    child: Center(
                      child: Text(
                        '${month.month.toString().padLeft(2, '0')}월',
                        style: TextStyle(
                          color: textColor,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    status.caption,
                    style: TextStyle(
                      color: ringColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPaymentHistoryList({
    required PaymentRecord upcomingRecord,
    double? maxHeight,
  }) {
    final studentId = widget.studentWithInfo.student.id;
    final registrationDate = widget.studentWithInfo.basicInfo.registrationDate;
    if (registrationDate == null) {
      return const Center(child: Text('등록일 정보가 없습니다.', style: TextStyle(color: Colors.white60)));
    }

    final now = DateTime.now();
    final currentMonth = DateTime(now.year, now.month);
    final List<DateTime> months = [];
    DateTime probe = DateTime(registrationDate.year, registrationDate.month);
    while (!probe.isAfter(DateTime(currentMonth.year, currentMonth.month + 3))) {
      months.add(probe);
      probe = DateTime(probe.year, probe.month + 1);
    }
    // 최신순 정렬
    months.sort((a, b) => b.compareTo(a));

    final DateTime today = DateTime.now();
    final DateTime upcomingDueDate = upcomingRecord.dueDate;
    final int upcomingCycle = upcomingRecord.cycle;
    final List<_PaymentEntry> pastEntries = [];
    _PaymentEntry? upcomingEntry;

    final sortedMonths = List<DateTime>.from(months)..sort((a, b) => a.compareTo(b));
    for (final month in sortedMonths) {
      final paymentDate = _getActualPaymentDateForMonth(studentId, registrationDate, month);
      final cycle = _calculateCycleNumber(registrationDate, paymentDate);
      final record = DataManager.instance.getPaymentRecord(studentId, cycle);
      final entry = _PaymentEntry(
        cycle: cycle,
        dueDate: paymentDate,
        record: record,
      );
      if (cycle == upcomingCycle) {
        upcomingEntry = entry;
        continue;
      }
      if (paymentDate.isAfter(upcomingDueDate)) {
        // 다음 달 예정일 이후의 기록은 숨김
        continue;
      }
      pastEntries.add(entry);
    }

    pastEntries.sort((a, b) => b.dueDate.compareTo(a.dueDate));
    final entries = [
      if (upcomingEntry != null) upcomingEntry,
      ...pastEntries,
    ];

    final TextStyle labelStyle = const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600);
    final TextStyle dateStyle = const TextStyle(color: Colors.white70, fontSize: 17);
    final double chipFontSize = 14;

    final listView = ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      physics: const BouncingScrollPhysics(),
      itemCount: entries.length,
      separatorBuilder: (_, __) => const Divider(color: Color(0xFF223131), height: 1),
            itemBuilder: (context, index) {
        final entry = entries[index];
        final bool isPaid = entry.record?.paidDate != null;
        final bool isUpcoming = entry.dueDate.isAfter(today);
        String statusText;
        Color statusColor;
        if (isPaid) {
          statusText = '납부';
          statusColor = const Color(0xFF33A373);
        } else if (isUpcoming) {
          statusText = '예정';
          statusColor = const Color(0xFFF2B45B);
        } else {
          statusText = '미납';
          statusColor = const Color(0xFFE57373);
        }

        return InkWell(
          onTap: () => _showPaymentDatePicker(
            entry.record ??
                PaymentRecord(studentId: studentId, cycle: entry.cycle, dueDate: entry.dueDate),
            markAsPaid: true,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Row(
        children: [
                Text('${entry.cycle}회차', style: labelStyle),
                const SizedBox(width: 20),
                Text(
                  DateFormat('yyyy.MM.dd').format(entry.dueDate),
                  style: dateStyle,
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity(0.18),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: statusColor.withOpacity(0.5)),
                  ),
                  child: Text(
                    statusText,
                    style: TextStyle(color: statusColor, fontSize: chipFontSize, fontWeight: FontWeight.w700),
                      ),
              ),
            ],
          ),
                ),
              );
            },
    );

    final scrollable = Scrollbar(child: listView);
    final content = maxHeight != null ? SizedBox(height: maxHeight, child: scrollable) : scrollable;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF151C21),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF223131)),
      ),
      child: content,
    );
  }

  List<AttendanceRecord> _uniqueAttendanceRecords(String studentId) {
    final records = DataManager.instance.getAttendanceRecordsForStudent(studentId)
      ..sort((a, b) => b.classDateTime.compareTo(a.classDateTime));
    final Map<DateTime, AttendanceRecord> uniqueMap = {};
    for (final record in records) {
      final dayKey = DateTime(record.classDateTime.year, record.classDateTime.month, record.classDateTime.day);
      final existing = uniqueMap[dayKey];
      if (existing == null || _compareAttendancePriority(record, existing) < 0) {
        uniqueMap[dayKey] = record;
      }
    }
    final result = uniqueMap.values.toList()
      ..sort((a, b) => b.classDateTime.compareTo(a.classDateTime));
    return result;
  }

  _MonthlyDotInfo _resolveMonthlyStatus(String studentId, DateTime registrationDate, DateTime month) {
    final DateTime regDate = DateTime(registrationDate.year, registrationDate.month, registrationDate.day);
    final DateTime dueDate = _getActualPaymentDateForMonth(studentId, regDate, month);
    if (dueDate.isBefore(regDate)) {
      return const _MonthlyDotInfo(color: Color(0xFF3C4747), caption: '미등록', dimmed: true);
    }
    final int cycle = _calculateCycleNumber(regDate, dueDate);
    if (cycle <= 0) {
      return const _MonthlyDotInfo(color: Color(0xFF3C4747), caption: '미등록', dimmed: true);
    }
    final record = DataManager.instance.getPaymentRecord(studentId, cycle);
    if (record?.paidDate != null) {
      return const _MonthlyDotInfo(color: Color(0xFF33A373), caption: '납부');
    }
    final DateTime now = DateTime.now();
    if (dueDate.isAfter(now)) {
      return const _MonthlyDotInfo(color: Color(0xFFF2B45B), caption: '예정');
    }
    return const _MonthlyDotInfo(color: Color(0xFFE57373), caption: '미납');
  }

  Widget _AddOverrideDot({required String studentId, required DateTime date}) {
    final overrides = DataManager.instance.sessionOverrides;
    final dateStart = DateTime(date.year, date.month, date.day);
    final dateEnd = dateStart.add(const Duration(days: 1));
    bool sameMinute(DateTime a, DateTime b) =>
        a.year == b.year && a.month == b.month && a.day == b.day && a.hour == b.hour && a.minute == b.minute;

    final overrideOnDate = overrides.where((o) =>
        o.studentId == studentId &&
        (o.overrideType == OverrideType.add || o.overrideType == OverrideType.replace) &&
        o.status != OverrideStatus.canceled &&
        o.replacementClassDateTime != null &&
        o.replacementClassDateTime!.isAfter(dateStart) &&
        o.replacementClassDateTime!.isBefore(dateEnd)).toList();

    if (overrideOnDate.isEmpty) return const SizedBox.shrink();

    final hasReplace = overrideOnDate.any((o) => o.overrideType == OverrideType.replace);
    final hasAdd = overrideOnDate.any((o) => o.overrideType == OverrideType.add);
    final labels = [
      if (hasReplace) '보강',
      if (hasAdd) '추가',
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        labels,
        style: const TextStyle(color: Color(0xFF5DD6FF), fontSize: 11, fontWeight: FontWeight.w700),
      ),
    );
  }

  // Helpers
  String _hhmm(DateTime? dt) {
    if (dt == null) return '--:--';
    return DateFormat('HH:mm').format(dt);
  }

  Future<void> _showPaymentDatePicker(PaymentRecord record, {required bool markAsPaid}) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: markAsPaid ? (record.paidDate ?? DateTime.now()) : record.dueDate,
      firstDate: DateTime(record.dueDate.year - 1, 1, 1),
      lastDate: DateTime(record.dueDate.year + 2, 12, 31),
      builder: (context, child) {
        return Theme(
          data: ThemeData.dark().copyWith(
            colorScheme: const ColorScheme.dark(
              primary: Color(0xFF1B6B63),
              onPrimary: Colors.white,
              surface: Color(0xFF151C21),
              onSurface: Colors.white,
            ),
            dialogBackgroundColor: const Color(0xFF151C21),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      if (markAsPaid) {
        // 미납/예정 항목 터치 시 실제 납부일을 기록
        await DataManager.instance.recordPayment(record.studentId, record.cycle, picked);
      } else {
        // 예정일 카드에서 수정 시 납부 처리 없이 예정일만 변경
        await DataManager.instance.postponeDueDate(
          record.studentId,
          record.cycle,
          picked,
          'manual_due_edit',
        );
      }
      if (mounted) setState(() {});
    }
  }
  
  DateTime _getActualPaymentDateForMonth(String studentId, DateTime registrationDate, DateTime targetMonth) {
    // registrationDate는 날짜만 사용 (시간 비교 오차 방지)
    final regDate = DateTime(registrationDate.year, registrationDate.month, registrationDate.day);
    final defaultDate = DateTime(targetMonth.year, targetMonth.month, regDate.day);
    final cycle = _calculateCycleNumber(regDate, defaultDate);
    final record = DataManager.instance.getPaymentRecord(studentId, cycle);
    if (record != null) return record.dueDate;
    return defaultDate;
  }

  int _calculateCycleNumber(DateTime registrationDate, DateTime paymentDate) {
    final regMonth = DateTime(registrationDate.year, registrationDate.month, 1);
    final payMonth = DateTime(paymentDate.year, paymentDate.month, 1);
    return (payMonth.year - regMonth.year) * 12 + (payMonth.month - regMonth.month) + 1;
  }
}

class _MonthlyDotInfo {
  final Color color;
  final String caption;
  final bool dimmed;

  const _MonthlyDotInfo({
    required this.color,
    required this.caption,
    this.dimmed = false,
  });
}

class _PaymentEntry {
  final int cycle;
  final DateTime dueDate;
  final PaymentRecord? record;

  _PaymentEntry({
    required this.cycle,
    required this.dueDate,
    required this.record,
  });
}

class _LegendEntry {
  final String label;
  final Color color;

  const _LegendEntry(this.label, this.color);
}

int _compareAttendancePriority(AttendanceRecord a, AttendanceRecord b) {
  return _attendanceRank(a).compareTo(_attendanceRank(b));
}

int _attendanceRank(AttendanceRecord record) {
  if (_isPresent(record) && !_isLate(record)) return 0; // 정상 출석
  if (_isPresent(record) && _isLate(record)) return 1; // 지각
  return 2; // 결석
}

bool _isPresent(AttendanceRecord record) => record.isPresent;

bool _isLate(AttendanceRecord record) {
  if (!record.isPresent || record.arrivalTime == null) return false;
  final lateThreshold = record.classDateTime.add(const Duration(minutes: 10));
  return record.arrivalTime!.isAfter(lateThreshold);
}

bool _isAbsent(AttendanceRecord record) => !record.isPresent;

class _TimeField extends StatelessWidget {
  final String label;
  final TextEditingController controller;

  const _TimeField({required this.label, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFF11181C),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFF2B3A42)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: TextField(
            controller: controller,
            style: const TextStyle(color: Colors.white, fontSize: 15, letterSpacing: 0.2),
            decoration: const InputDecoration(
              border: InputBorder.none,
              hintText: 'HH:MM',
              hintStyle: TextStyle(color: Colors.white38),
            ),
          ),
        ),
      ],
    );
  }
}

String _resolveDisplayClassName(AttendanceRecord record, SessionOverride? matchedOverride) {
  // 우선: record.className이 있고 '수업'이 아니면 그대로 사용
  final raw = record.className?.trim();
  if (raw != null && raw.isNotEmpty && raw != '수업') return raw;

  // 보강/추가수업에서 sessionTypeId로 클래스명 찾기
  if (matchedOverride?.sessionTypeId != null) {
    try {
      final cls = DataManager.instance.classes.firstWhere((c) => c.id == matchedOverride!.sessionTypeId);
      if (cls.name.trim().isNotEmpty) return cls.name.trim();
    } catch (_) {}
  }

  // 기본값
  return '정규 수업';
}
