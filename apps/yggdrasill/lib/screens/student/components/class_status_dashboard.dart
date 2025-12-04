import 'package:flutter/material.dart';

import '../../../models/payment_record.dart';
import '../../../services/data_manager.dart';

// AllStudentsView와 통일된 색상 팔레트
const Color _primaryTextColor = Color(0xFFEAF2F2);
const Color _mutedTextColor = Color(0xFFCBD8D8); // 0xFF94A3A3에서 변경
const Color _cardBackgroundColor = Color(0xFF15171C); // 그룹 카드 배경색
const Color _borderColor = Color(0xFF223131); // 테두리 색상

class ClassStatusDashboard extends StatefulWidget {
  const ClassStatusDashboard({super.key, this.isFullPage = false});

  final bool isFullPage;

  @override
  State<ClassStatusDashboard> createState() => _ClassStatusDashboardState();
}

class _ClassStatusDashboardState extends State<ClassStatusDashboard> {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<StudentWithInfo>>(
      valueListenable: DataManager.instance.studentsNotifier,
      builder: (context, students, _) {
        return ValueListenableBuilder<List<PaymentRecord>>(
          valueListenable: DataManager.instance.paymentRecordsNotifier,
          builder: (context, paymentRecords, __) {
            return _buildDashboard(
              context: context,
              students: students,
              paymentRecords: paymentRecords,
            );
          },
        );
      },
    );
  }

  Widget _buildDashboard({
    required BuildContext context,
    required List<StudentWithInfo> students,
    required List<PaymentRecord> paymentRecords,
  }) {
    final DateTime now = DateTime.now();
    final Set<String> activeStudentIds = students.map((s) => s.student.id).toSet();

    final DateTime monthStart = DateTime(now.year, now.month, 1);
    final DateTime nextMonthStart = DateTime(now.year, now.month + 1, 1);
    int monthPaid = 0, monthDue = 0;
    for (final pr in paymentRecords) {
      if (!activeStudentIds.contains(pr.studentId)) continue;
      final due = pr.dueDate;
      final paid = pr.paidDate;
      final bool isThisMonth = due.isAfter(monthStart.subtract(const Duration(milliseconds: 1))) && due.isBefore(nextMonthStart);
      if (isThisMonth) {
        if (paid != null) {
          monthPaid++;
        } else {
          monthDue++;
        }
      }
    }

    // 타일 위젯 (요약 카드) - 학생 탭 그룹 카드 스타일 적용
    Widget tile(
      String title,
      String big,
      String sub, {
      Color accent = const Color(0xFF90CAF9),
      Widget? trailing,
    }) {
      final double screenW = MediaQuery.of(context).size.width;
      const double minW = 1430;
      const double maxW = 2200;
      const double fsMin = 20; // 폰트 사이즈 약간 키움
      const double fsMax = 26;
      double t = ((screenW - minW) / (maxW - minW)).clamp(0.0, 1.0);
      final double bigFontSize = fsMin + (fsMax - fsMin) * t;
      
      return Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: _cardBackgroundColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _borderColor, width: 1.5),
          // 그림자 제거 (Flat Style)
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              children: [
                Text(
                  title,
                  style: const TextStyle(color: _mutedTextColor, fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (trailing != null) trailing,
              ],
            ),
            const SizedBox(height: 12),
            Text(
              big,
              style: TextStyle(color: accent, fontSize: bigFontSize, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              sub,
              style: const TextStyle(color: Colors.white54, fontSize: 14),
            ),
          ],
        ),
      );
    }

    final DateTime thisMonth = DateTime(now.year, now.month);
    final DateTime prevMonth = DateTime(now.year, now.month - 1);
    final DateTime prevMonthEnd = DateTime(
      prevMonth.year,
      prevMonth.month,
      DateUtils.getDaysInMonth(prevMonth.year, prevMonth.month),
    );
    final Map<String, DateTime> monthPaidByStudent = {};
    final Map<String, DateTime> prevMonthPaidByStudent = {};
    final Map<String, DateTime> monthDueByStudent = {};
    final Map<String, DateTime> prevMonthDueByStudent = {};

    DateTime clampToMonthLastDay(DateTime candidate) {
      final int y = candidate.year, m = candidate.month;
      final int lastDay = DateUtils.getDaysInMonth(y, m);
      final int day = candidate.day > lastDay ? lastDay : candidate.day;
      return DateTime(y, m, day);
    }

    for (final s in students) {
      final String sid = s.student.id;
      if (!activeStudentIds.contains(sid)) continue;
      final DateTime reg = (s.registrationDate ?? s.basicInfo.registrationDate) ?? DateTime.now();
      final DateTime baseDueThis = DateTime(thisMonth.year, thisMonth.month, reg.day);
      final DateTime dueThis = clampToMonthLastDay(baseDueThis);
      final int cycleThis = _calculateCycleNumber(reg, dueThis);
      final recordThis = DataManager.instance.getPaymentRecord(sid, cycleThis);
      monthDueByStudent[sid] = recordThis?.dueDate ?? dueThis;
      if (recordThis?.paidDate != null) {
        monthPaidByStudent[sid] = recordThis!.paidDate!;
      }
      if (!reg.isAfter(prevMonthEnd)) {
        final DateTime baseDuePrev = DateTime(prevMonth.year, prevMonth.month, reg.day);
        final DateTime duePrev = clampToMonthLastDay(baseDuePrev);
        final int cyclePrev = _calculateCycleNumber(reg, duePrev);
        final recordPrev = DataManager.instance.getPaymentRecord(sid, cyclePrev);
        prevMonthDueByStudent[sid] = recordPrev?.dueDate ?? duePrev;
        if (recordPrev?.paidDate != null) {
          prevMonthPaidByStudent[sid] = recordPrev!.paidDate!;
        }
      }
    }

    final Map<String, _DashboardAttendanceInfo> thisMonthPaymentByStudent = {
      for (final entry in monthDueByStudent.entries)
        entry.key: _DashboardAttendanceInfo(
          arrival: monthPaidByStudent[entry.key],
          departure: null,
          isPresent: monthPaidByStudent[entry.key] != null,
          isLate: false,
          classDateTime: entry.value,
        ),
    };

    final Map<String, _DashboardAttendanceInfo> prevMonthPaymentByStudent = {
      for (final entry in prevMonthDueByStudent.entries)
        entry.key: _DashboardAttendanceInfo(
          arrival: prevMonthPaidByStudent[entry.key],
          departure: null,
          isPresent: prevMonthPaidByStudent[entry.key] != null,
          isLate: false,
          classDateTime: entry.value,
        ),
    };

    String nameOf(String studentId) {
      try {
        return students.firstWhere((s) => s.student.id == studentId).student.name;
      } catch (_) {
        return studentId;
      }
    }

    // 리스트 아이템 (Simple Row) - 학생 탭 리스트 아이템 스타일
    Widget simpleRow(
      String left, {
      required Widget statusLine,
      String? timeLine,
    }) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: _cardBackgroundColor.withOpacity(0.5), // 약간 투명하게
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _borderColor.withOpacity(0.6)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          left,
                          style: const TextStyle(
                            color: _primaryTextColor,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      statusLine,
                    ],
                  ),
                ),
              ],
            ),
            if (timeLine != null) ...[
              const SizedBox(height: 6),
              Text(
                timeLine,
                style: const TextStyle(color: _mutedTextColor, fontSize: 13),
              ),
            ],
          ],
        ),
      );
    }

    Widget listFor(
      Map<String, _DashboardAttendanceInfo> data, {
      bool sortByDue = false,
    }) {
      if (data.isEmpty) {
        return Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _borderColor.withOpacity(0.5), style: BorderStyle.solid),
          ),
          child: const Center(
            child: Text('기록 없음', style: TextStyle(color: Colors.white38, fontSize: 14)),
          ),
        );
      }

      final entries = data.entries.toList();
      if (sortByDue) {
        entries.sort((a, b) => a.value.classDateTime.compareTo(b.value.classDateTime));
      }

      return Column(
        children: entries.map((e) {
          final name = nameOf(e.key);
          final info = e.value;
          final paid = info.arrival;
          final due = info.classDateTime;
          final Widget rightWidget = Text(
            paid != null ? '납부' : '미납',
            style: TextStyle(
              color: paid != null ? _mutedTextColor : const Color(0xFFE53E3E),
              fontSize: 14,
              fontWeight: paid != null ? FontWeight.w500 : FontWeight.w700,
            ),
          );
          final String timeLineStr = paid != null
              ? '예정 ${due.month}/${due.day} · 납부 ${paid.month}/${paid.day}'
              : '예정 ${due.month}/${due.day}';

          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: InkWell(
              onTap: null,
              borderRadius: BorderRadius.circular(12),
              child: simpleRow(
                name,
                statusLine: rightWidget,
                timeLine: timeLineStr,
              ),
            ),
          );
        }).toList(),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.only(right: 8, bottom: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                tile(
                  '지난달 납입',
                  '납부 ${prevMonthPaidByStudent.length} · 총 인원 ${prevMonthDueByStudent.length}',
                  '${now.month - 1 <= 0 ? 12 : now.month - 1}월 납부 현황',
                  accent: const Color(0xFF90CAF9),
                  trailing: _buildActionButton('리스트', _showRecentPaymentDialog),
                ),
                listFor(prevMonthPaymentByStudent, sortByDue: true),
              ],
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                tile(
                  '이번달 납입',
                  '납부 ${monthPaidByStudent.length} · 총 인원 ${monthDueByStudent.length}',
                  '${now.month}월 납부 현황',
                  accent: const Color(0xFF90CAF9),
                ),
                listFor(thisMonthPaymentByStudent, sortByDue: true),
              ],
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildActionButton(String label, VoidCallback onPressed) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.list_rounded, color: _primaryTextColor, size: 18),
      label: Text(label, style: const TextStyle(color: _primaryTextColor, fontSize: 13)),
      style: TextButton.styleFrom(
        backgroundColor: Colors.white.withOpacity(0.1),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        foregroundColor: _primaryTextColor,
      ),
    );
  }

  int _calculateCycleNumber(DateTime registrationDate, DateTime paymentDate) {
    final regMonth = DateTime(registrationDate.year, registrationDate.month);
    final payMonth = DateTime(paymentDate.year, paymentDate.month);
    return (payMonth.year - regMonth.year) * 12 + (payMonth.month - regMonth.month) + 1;
  }

  Future<void> _showRecentPaymentDialog() async {
    await showDialog(
      context: context,
      builder: (context) {
        DateTime anchor = DateTime(DateTime.now().year, DateTime.now().month, 1);
        return StatefulBuilder(
          builder: (context, setLocalState) {
            List<DateTime> months = List.generate(5, (i) => DateTime(anchor.year, anchor.month - i, 1));
            months.sort();

            Widget monthTile(DateTime month) {
              final Set<String> activeStudentIds = DataManager.instance.students.map((s) => s.student.id).toSet();
              DateTime clampToMonthEnd(DateTime m, DateTime reg) {
                final int last = DateUtils.getDaysInMonth(m.year, m.month);
                final int d = reg.day > last ? last : reg.day;
                return DateTime(m.year, m.month, d);
              }

              final List<_DashboardAttendanceInfo> monthInfos = [];
              for (final s in DataManager.instance.students) {
                if (!activeStudentIds.contains(s.student.id)) continue;
                final DateTime reg = (s.registrationDate ?? s.basicInfo.registrationDate) ?? DateTime.now();
                final DateTime monthEnd = DateTime(month.year, month.month, DateUtils.getDaysInMonth(month.year, month.month));
                if (reg.isAfter(monthEnd)) continue;
                final DateTime due = clampToMonthEnd(month, reg);
                final int cycle = _calculateCycleNumber(reg, due);
                final rec = DataManager.instance.getPaymentRecord(s.student.id, cycle);
                monthInfos.add(
                  _DashboardAttendanceInfo(
                    arrival: rec?.paidDate,
                    departure: null,
                    isPresent: rec?.paidDate != null,
                    isLate: false,
                    classDateTime: rec?.dueDate ?? due,
                  ),
                );
              }
              monthInfos.sort((a, b) => a.classDateTime.compareTo(b.classDateTime));
              return Container(
                margin: const EdgeInsets.symmetric(vertical: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _cardBackgroundColor,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _borderColor),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          '${month.year}.${month.month.toString().padLeft(2, '0')}',
                          style: const TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                        const Spacer(),
                        Text('총 ${monthInfos.length}건', style: const TextStyle(color: Colors.white38, fontSize: 13)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Column(
                      children: monthInfos.map((info) {
                        final paid = info.arrival;
                        final due = info.classDateTime;
                        final name = _lookupStudentNameByDue(month, due);
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  name,
                                  style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                paid != null ? '납부' : '미납',
                                style: TextStyle(
                                  color: paid != null ? Colors.white70 : const Color(0xFFE53E3E),
                                  fontWeight: paid != null ? FontWeight.w400 : FontWeight.w700,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                paid != null ? '예정 ${due.month}/${due.day} · 납부 ${paid.month}/${paid.day}' : '예정 ${due.month}/${due.day}',
                                style: const TextStyle(color: Colors.white54, fontSize: 12),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              );
            }

            return Dialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              backgroundColor: const Color(0xFF1F1F1F),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final double dialogWidth = (constraints.maxWidth * 0.64).clamp(768.0, constraints.maxWidth);
                  final double dialogHeight = (constraints.maxHeight * 0.77).clamp(448.0, constraints.maxHeight);
                  return ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: dialogWidth,
                      maxHeight: dialogHeight,
                    ),
                    child: Container(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.max,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              IconButton(
                                onPressed: () => setLocalState(() => anchor = DateTime(anchor.year, anchor.month - 5, 1)),
                                icon: const Icon(Icons.chevron_left, color: Colors.white70),
                              ),
                              IconButton(
                                onPressed: () async {
                                  final picked = await showDatePicker(
                                    context: context,
                                    initialDate: anchor,
                                    firstDate: DateTime(anchor.year - 5, 1, 1),
                                    lastDate: DateTime(anchor.year + 5, 12, 31),
                                    locale: const Locale('ko', 'KR'),
                                    builder: (context, child) {
                                      return Theme(
                                        data: Theme.of(context).copyWith(
                                          colorScheme: const ColorScheme.dark(
                                            primary: Color(0xFF1976D2),
                                            onPrimary: Colors.white,
                                            surface: Color(0xFF2A2A2A),
                                            onSurface: Colors.white,
                                          ),
                                        ),
                                        child: child!,
                                      );
                                    },
                                  );
                                  if (picked != null) {
                                    setLocalState(() => anchor = DateTime(picked.year, picked.month, 1));
                                  }
                                },
                                icon: const Icon(Icons.calendar_month, color: Colors.white70),
                                tooltip: '월 선택',
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '최근 납부 ( ${anchor.year}.${anchor.month.toString().padLeft(2, '0')} 기준 )',
                                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
                              ),
                              const Spacer(),
                              IconButton(
                                onPressed: () => setLocalState(() => anchor = DateTime(anchor.year, anchor.month + 5, 1)),
                                icon: const Icon(Icons.chevron_right, color: Colors.white70),
                              ),
                              IconButton(
                                onPressed: () => Navigator.of(context).pop(),
                                icon: const Icon(Icons.close, color: Colors.white70),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Expanded(
                            child: LayoutBuilder(
                              builder: (context, box) {
                                const int columns = 5;
                                const double spacing = 16.0;
                                final double colWidth = (box.maxWidth - spacing * (columns - 1)) / columns;
                                final List<Widget> children = [];
                                for (int i = 0; i < months.length; i++) {
                                  children.add(SizedBox(width: colWidth, child: monthTile(months[i])));
                                  if (i < months.length - 1) {
                                    children.add(const SizedBox(width: spacing));
                                  }
                                }
                                return SingleChildScrollView(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: children,
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }

  String _lookupStudentNameByDue(DateTime month, DateTime dueDate) {
    for (final s in DataManager.instance.students) {
      final DateTime reg = (s.registrationDate ?? s.basicInfo.registrationDate) ?? DateTime.now();
      final DateTime clamp = DateTime(month.year, month.month, reg.day > DateUtils.getDaysInMonth(month.year, month.month) ? DateUtils.getDaysInMonth(month.year, month.month) : reg.day);
      if (clamp.year == dueDate.year && clamp.month == dueDate.month && clamp.day == dueDate.day) {
        return s.student.name;
      }
    }
    return '-';
  }
}

class _DashboardAttendanceInfo {
  final DateTime? arrival;
  final DateTime? departure;
  final bool isPresent;
  final bool isLate;
  final DateTime classDateTime;

  const _DashboardAttendanceInfo({
    required this.arrival,
    required this.departure,
    required this.isPresent,
    required this.isLate,
    required this.classDateTime,
  });
}
