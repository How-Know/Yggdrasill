import 'package:flutter/material.dart';

import '../../../models/attendance_record.dart';
import '../../../models/student.dart';
import '../../../services/data_manager.dart';
import '../../timetable/components/attendance_check_view.dart';

const Color _primaryTextColor = Color(0xFFEAF2F2);
const Color _mutedTextColor = Color(0xFFCBD8D8);
const Color _cardBackgroundColor = Color(0xFF15171C);
const Color _borderColor = Color(0xFF223131);

class AttendanceStatusDashboard extends StatefulWidget {
  final bool isFullPage;

  const AttendanceStatusDashboard({super.key, this.isFullPage = false});

  @override
  State<AttendanceStatusDashboard> createState() => _AttendanceStatusDashboardState();
}

class _AttendanceStatusDashboardState extends State<AttendanceStatusDashboard> {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<StudentWithInfo>>(
      valueListenable: DataManager.instance.studentsNotifier,
      builder: (context, students, _) {
        return ValueListenableBuilder<List<AttendanceRecord>>(
          valueListenable: DataManager.instance.attendanceRecordsNotifier,
          builder: (context, attendanceRecords, __) {
            return _buildDashboard(
              context: context,
              students: students,
              attendanceRecords: attendanceRecords,
            );
          },
        );
      },
    );
  }

  Widget _buildDashboard({
    required BuildContext context,
    required List<StudentWithInfo> students,
    required List<AttendanceRecord> attendanceRecords,
  }) {
    final DateTime now = DateTime.now();
    final DateTime todayStart = DateTime(now.year, now.month, now.day);
    final DateTime todayEnd = todayStart.add(const Duration(days: 1));
    final DateTime yesterdayStart = todayStart.subtract(const Duration(days: 1));
    final DateTime yesterdayEnd = todayStart;

    final Set<String> activeStudentIds = students.map((s) => s.student.id).toSet();

    int yPresent = 0, yLate = 0, yAbsent = 0;
    int tPresent = 0, tLate = 0, tAbsent = 0;

    const int defaultLateMinutes = 10;

    final Map<String, _AttendanceInfo> yesterdayAttendanceByStudent = {};
    final Map<String, _AttendanceInfo> todayAttendanceByStudent = {};

    for (final r in attendanceRecords) {
      if (!activeStudentIds.contains(r.studentId)) continue;
      final dt = r.classDateTime;
      final bool isYesterday = dt.isAfter(yesterdayStart) && dt.isBefore(yesterdayEnd);
      final bool isToday = dt.isAfter(todayStart) && dt.isBefore(todayEnd);
      if (!isYesterday && !isToday) continue;

      final bool isLate = r.arrivalTime != null && r.arrivalTime!.isAfter(r.classDateTime.add(const Duration(minutes: defaultLateMinutes)));

      if (!r.isPresent) {
        if (isYesterday) {
          yAbsent++;
        } else {
          tAbsent++;
        }
      } else if (isLate) {
        if (isYesterday) {
          yLate++;
        } else {
          tLate++;
        }
      } else {
        if (isYesterday) {
          yPresent++;
        } else {
          tPresent++;
        }
      }

      if (isYesterday) {
        yesterdayAttendanceByStudent[r.studentId] = _AttendanceInfo(
          arrival: r.arrivalTime,
          departure: r.departureTime,
          isPresent: r.isPresent,
          isLate: isLate,
          classDateTime: r.classDateTime,
        );
      } else if (isToday) {
        todayAttendanceByStudent[r.studentId] = _AttendanceInfo(
          arrival: r.arrivalTime,
          departure: r.departureTime,
          isPresent: r.isPresent,
          isLate: isLate,
          classDateTime: r.classDateTime,
        );
      }
    }

    Widget tile(
      String title,
      String big,
      String sub, {
      Widget? trailing,
    }) {
      final double screenW = MediaQuery.of(context).size.width;
      const double minW = 1430;
      const double maxW = 2200;
      const double fsMin = 20;
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
              style: TextStyle(color: const Color(0xFF64B5F6), fontSize: bigFontSize, fontWeight: FontWeight.w700),
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

    Widget simpleRow(String studentId, String left, _AttendanceInfo info) {
      final Widget statusLine;
      if (!info.isPresent) {
        statusLine = const Text(
          '결석',
          style: TextStyle(
            color: Color(0xFFE53E3E),
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        );
      } else if (info.isLate) {
        statusLine = const Text(
          '지각',
          style: TextStyle(
            color: Color(0xFFFF9800),
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        );
      } else {
        statusLine = const Text(
          '출석',
          style: TextStyle(
            color: Color(0xFF7BD8A0),
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        );
      }

      return InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async => _jumpToAttendanceEdit(studentId, info.classDateTime),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: _cardBackgroundColor.withOpacity(0.5),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _borderColor.withOpacity(0.6)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
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
              if (info.isPresent) ...[
                const SizedBox(height: 6),
                Text(
                  '등원 ${_hhmm(info.arrival)} · 하원 ${_hhmm(info.departure)}',
                  style: const TextStyle(color: _mutedTextColor, fontSize: 13),
                ),
              ],
            ],
          ),
        ),
      );
    }

    Widget listFor(Map<String, _AttendanceInfo> data) {
      if (data.isEmpty) {
        return Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _borderColor.withOpacity(0.5)),
          ),
          child: const Center(
            child: Text('기록 없음', style: TextStyle(color: Colors.white38, fontSize: 14)),
          ),
        );
      }
      final entries = data.entries.toList()
        ..sort((a, b) => a.value.classDateTime.compareTo(b.value.classDateTime));
      return Column(
        children: entries.map((entry) {
          final studentName = _nameOf(entry.key);
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: simpleRow(entry.key, studentName, entry.value),
          );
        }).toList(),
      );
    }

    return SingleChildScrollView(
      padding: widget.isFullPage ? const EdgeInsets.only(right: 8, bottom: 16) : EdgeInsets.zero,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                tile(
                  '어제 출결',
                  '출석 ${yPresent + yLate} · 결석 $yAbsent',
                  '지각 $yLate',
                  trailing: _buildActionButton('리스트', _showRecentAttendanceDialog),
                ),
                listFor(yesterdayAttendanceByStudent),
              ],
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                tile(
                  '오늘 출결',
                  '출석 ${tPresent + tLate} · 결석 $tAbsent',
                  '지각 $tLate',
                ),
                listFor(todayAttendanceByStudent),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton(String label, Future<void> Function() onPressed) {
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

  String _nameOf(String studentId) {
    try {
      return DataManager.instance.students.firstWhere((s) => s.student.id == studentId).student.name;
    } catch (_) {
      return studentId;
    }
  }

  Future<void> _jumpToAttendanceEdit(String studentId, DateTime classDateTime) async {
    try {
      final record = DataManager.instance.getAttendanceRecord(studentId, classDateTime);
      final int duration = DataManager.instance.academySettings.lessonDuration;
      const String className = '-';

      if (record == null || !record.isPresent) {
        await DataManager.instance.saveOrUpdateAttendance(
          studentId: studentId,
          classDateTime: classDateTime,
          classEndTime: classDateTime.add(Duration(minutes: duration)),
          className: className,
          isPresent: true,
          arrivalTime: classDateTime,
          departureTime: classDateTime.add(Duration(minutes: duration)),
        );
      } else {
        await showAttendanceEditDialog(
          context: context,
          studentId: studentId,
          classDateTime: classDateTime,
          durationMinutes: duration,
          className: className,
        );
      }
    } catch (e) {
      debugPrint('Failed to open attendance edit dialog: $e');
    }
  }

  String _hhmm(DateTime? dateTime) {
    if (dateTime == null) return '--:--';
    final String hours = dateTime.hour.toString().padLeft(2, '0');
    final String minutes = dateTime.minute.toString().padLeft(2, '0');
    return '$hours:$minutes';
  }

  Future<void> _showRecentAttendanceDialog() async {
    await showDialog(
      context: context,
      builder: (context) {
        DateTime anchor = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
        return StatefulBuilder(
          builder: (context, setLocalState) {
            final DateTime start = anchor.subtract(const Duration(days: 5));
            final DateTime end = anchor;
            final Set<String> activeStudentIds = DataManager.instance.students.map((s) => s.student.id).toSet();
            final Map<DateTime, List<AttendanceRecord>> byDay = {};
            for (final r in DataManager.instance.attendanceRecords) {
              if (!activeStudentIds.contains(r.studentId)) continue;
              final d = DateTime(r.classDateTime.year, r.classDateTime.month, r.classDateTime.day);
              if (d.isAfter(start.subtract(const Duration(milliseconds: 1))) && d.isBefore(end.add(const Duration(days: 1)))) {
                (byDay[d] ??= []).add(r);
              }
            }

            List<DateTime> days = List.generate(5, (i) => anchor.subtract(Duration(days: i))).toList();
            days.sort();

            Widget dayTile(DateTime day) {
              final items = (byDay[day] ?? []).toList()..sort((a, b) => a.studentId.compareTo(b.studentId));
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
                          '${day.month}/${day.day}',
                          style: const TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                        const Spacer(),
                        Text(
                          '총 ${items.length}건',
                          style: const TextStyle(color: Colors.white38, fontSize: 13),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (items.isEmpty)
                      const Text('기록 없음', style: TextStyle(color: Colors.white54, fontSize: 13))
                    else
                      Column(
                        children: items.map((r) {
                          final name = DataManager.instance.students.firstWhere((s) => s.student.id == r.studentId).student.name;
                          final lateThreshold = DataManager.instance.getStudentPaymentInfo(r.studentId)?.latenessThreshold ?? 10;
                          final bool isLate = r.arrivalTime != null && r.arrivalTime!.isAfter(r.classDateTime.add(Duration(minutes: lateThreshold)));
                          final status = !r.isPresent
                              ? const Text('결석', style: TextStyle(color: Color(0xFFE53E3E), fontWeight: FontWeight.w700))
                              : Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (isLate)
                                      const Text('지각', style: TextStyle(color: Color(0xFFFF9800), fontWeight: FontWeight.w700)),
                                  ],
                                );
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        name,
                                        style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    status,
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '등원 ${_hhmm(r.arrivalTime)} · 하원 ${_hhmm(r.departureTime)}',
                                  style: const TextStyle(color: Colors.white70, fontSize: 12),
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
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              IconButton(
                                onPressed: () => setLocalState(() => anchor = anchor.subtract(const Duration(days: 5))),
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
                                    setLocalState(() => anchor = DateTime(picked.year, picked.month, picked.day));
                                  }
                                },
                                icon: const Icon(Icons.calendar_month, color: Colors.white70),
                                tooltip: '날짜 선택',
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '최근 출결 ( ${anchor.month}/${anchor.day} 기준 )',
                                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
                              ),
                              const Spacer(),
                              IconButton(
                                onPressed: () => setLocalState(() => anchor = anchor.add(const Duration(days: 5))),
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
                                for (int i = 0; i < days.length; i++) {
                                  children.add(SizedBox(width: colWidth, child: dayTile(days[i])));
                                  if (i < days.length - 1) {
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
}

class _AttendanceInfo {
  final DateTime? arrival;
  final DateTime? departure;
  final bool isPresent;
  final bool isLate;
  final DateTime classDateTime;

  const _AttendanceInfo({
    required this.arrival,
    required this.departure,
    required this.isPresent,
    required this.isLate,
    required this.classDateTime,
  });
}

