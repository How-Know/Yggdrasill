import 'package:flutter/material.dart';

import '../../../models/class_info.dart';
import '../../../models/student.dart';
import '../../../models/student_time_block.dart';
import '../../../models/attendance_record.dart';
import '../../../models/session_override.dart';
import '../../../services/data_manager.dart';
import '../../../widgets/pill_tab_selector.dart';

/// 학생의 "시간 관련 기록"을 요약해서 보여주는 다이얼로그.
///
/// - 탭: '일정 기록', '출석 기록'(준비중)
/// - 일정 기록: student_time_blocks 전체(닫힘/활성/미래 포함) 리스트
class StudentTimeInfoDialog extends StatefulWidget {
  final StudentWithInfo student;

  const StudentTimeInfoDialog({
    super.key,
    required this.student,
  });

  static Future<void> show(BuildContext context, StudentWithInfo student) async {
    await showDialog<void>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: true,
      builder: (_) => StudentTimeInfoDialog(student: student),
    );
  }

  @override
  State<StudentTimeInfoDialog> createState() => _StudentTimeInfoDialogState();
}

class _StudentTimeInfoDialogState extends State<StudentTimeInfoDialog> {
  int _tabIndex = 0;
  bool _resettingPlanned = false;

  @override
  Widget build(BuildContext context) {
    const bg = Color(0xFF0B1112);
    const panel = Color(0xFF15171C);
    const border = Color(0xFF223131);
    const text = Color(0xFFEAF2F2);
    const sub = Colors.white70;

    return Dialog(
      backgroundColor: bg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 980,
        height: 720,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${widget.student.student.name} · 시간 기록',
                      style: const TextStyle(color: text, fontSize: 18, fontWeight: FontWeight.w900),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Tooltip(
                    message: '예정 수업 초기화/재생성',
                    child: IconButton(
                      onPressed: _resettingPlanned
                          ? null
                          : () async {
                              final ok = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  backgroundColor: bg,
                                  title: const Text('예정 수업 재생성', style: TextStyle(color: text, fontWeight: FontWeight.w900)),
                                  content: const Text(
                                    '이 학생의 "순수 예정 수업"(is_planned=true, 출석/등원 기록 없는 것)만 전부 삭제한 뒤,\n'
                                    '현재 시간표(student_time_blocks)를 기준으로 예정 수업을 다시 생성합니다.\n\n'
                                    '출석/등원/하원 기록이 있는 행은 삭제하지 않습니다.',
                                    style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600, height: 1.35),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.of(ctx).pop(false),
                                      child: const Text('취소', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
                                    ),
                                    TextButton(
                                      onPressed: () => Navigator.of(ctx).pop(true),
                                      child: const Text('재생성', style: TextStyle(color: Color(0xFF33A373), fontWeight: FontWeight.w900)),
                                    ),
                                  ],
                                ),
                              );
                              if (ok != true) return;
                              setState(() => _resettingPlanned = true);
                              try {
                                await DataManager.instance.resetPlannedAttendanceForStudent(
                                  widget.student.student.id,
                                  days: 60,
                                );
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('예정 수업이 재생성되었습니다.')),
                                  );
                                }
                              } catch (e) {
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('재생성 실패: $e')),
                                  );
                                }
                              } finally {
                                if (mounted) setState(() => _resettingPlanned = false);
                              }
                            },
                      icon: _resettingPlanned
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh, color: sub, size: 20),
                    ),
                  ),
                  IconButton(
                    tooltip: '닫기',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close, color: sub, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // ✅ 큰 컨테이너 박스는 제거하고, 탭만 배치한다.
              Center(
                child: PillTabSelector(
                selectedIndex: _tabIndex,
                tabs: const ['일정 기록', '출석 기록'],
                onTabSelected: (i) => setState(() => _tabIndex = i),
                ),
              ),
              const SizedBox(height: 6),
              Divider(color: border, height: 1),
              const SizedBox(height: 14),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: panel,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: border, width: 1),
                  ),
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  child: _tabIndex == 0
                      ? _ScheduleHistoryTab(studentId: widget.student.student.id)
                      : _AttendanceHistoryTab(studentId: widget.student.student.id),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScheduleHistoryTab extends StatelessWidget {
  final String studentId;
  const _ScheduleHistoryTab({required this.studentId});

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
  static String _ymd(DateTime d) => '${d.year}.${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')}';
  static String _hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  static String _hmFromMinutes(int minutes) {
    final hh = (minutes ~/ 60).toString().padLeft(2, '0');
    final mm = (minutes % 60).toString().padLeft(2, '0');
    return '$hh:$mm';
  }
  static String _weekday(int dayIndex) {
    switch (dayIndex) {
      case 0:
        return '월';
      case 1:
        return '화';
      case 2:
        return '수';
      case 3:
        return '목';
      case 4:
        return '금';
      case 5:
        return '토';
      case 6:
        return '일';
    }
    return '?';
  }

  @override
  Widget build(BuildContext context) {
    const border = Color(0xFF223131);
    const text = Color(0xFFEAF2F2);

    final listenable = Listenable.merge([
      DataManager.instance.studentTimeBlocksRevision,
      DataManager.instance.classesRevision,
    ]);

    return AnimatedBuilder(
      animation: listenable,
      builder: (context, _) {
        final today = _dateOnly(DateTime.now());

        final raw = DataManager.instance.studentTimeBlocks.where((b) => b.studentId == studentId).toList();

        final classById = <String, ClassInfo>{
          for (final c in DataManager.instance.classes) c.id: c,
        };

        if (raw.isEmpty) {
          return const Center(
            child: Text(
              '수업 블록 기록이 없습니다.',
              style: TextStyle(color: Colors.white54, fontSize: 15, fontWeight: FontWeight.w600),
            ),
          );
        }

        // === 같은 set_id(=30분 블록 묶음)는 1개 row로 합친다. ===
        // - 기간(start/end) + 요일 기준으로 묶고
        // - 시간은 가장 빠른 시작 ~ 마지막 블록 끝 시간으로 표현한다.
        final Map<String, List<StudentTimeBlock>> grouped = <String, List<StudentTimeBlock>>{};
        for (final b in raw) {
          final setId = (b.setId ?? '').trim();
          final sd = _ymd(_dateOnly(b.startDate));
          final ed = b.endDate == null ? 'null' : _ymd(_dateOnly(b.endDate!));
          final sess = (b.sessionTypeId ?? '').trim();
          final key = setId.isEmpty
              ? 'single:${b.id}'
              : 'set:$setId|sd:$sd|ed:$ed|day:${b.dayIndex}|sess:$sess';
          grouped.putIfAbsent(key, () => <StudentTimeBlock>[]).add(b);
        }

        final entries = grouped.entries.map((e) {
          final blocks = e.value;
          final any = blocks.first;
          final setId = (any.setId ?? '').trim();
          final sd = blocks.map((b) => _dateOnly(b.startDate)).reduce((a, b) => a.isBefore(b) ? a : b);
          DateTime? ed;
          for (final b in blocks) {
            if (b.endDate == null) {
              ed = null;
              break;
            }
            final dd = _dateOnly(b.endDate!);
            ed = ed == null ? dd : (dd.isAfter(ed) ? dd : ed);
          }
          final dayIdx = blocks.map((b) => b.dayIndex).reduce((a, b) => a < b ? a : b);
          final startMin = blocks.map((b) => b.startHour * 60 + b.startMinute).reduce((a, b) => a < b ? a : b);
          final endMin = blocks
              .map((b) => (b.startHour * 60 + b.startMinute) + b.duration.inMinutes)
              .reduce((a, b) => a > b ? a : b);
          final modifiedAt = blocks.map((b) => b.createdAt).reduce((a, b) => a.isAfter(b) ? a : b);
          final sess = blocks.map((b) => (b.sessionTypeId ?? '').trim()).firstWhere((s) => s.isNotEmpty, orElse: () => (any.sessionTypeId ?? '').trim());
          return _ScheduleEntry(
            key: e.key,
            setId: setId.isEmpty ? null : setId,
            startDate: sd,
            endDate: ed,
            dayIndex: dayIdx,
            startMinute: startMin,
            endMinute: endMin,
            sessionTypeId: sess.isEmpty ? null : sess,
            modifiedAt: modifiedAt,
          );
        }).toList();

        int statusOrder(_ScheduleEntry it) {
          final sd = _dateOnly(it.startDate);
          final ed = it.endDate == null ? null : _dateOnly(it.endDate!);
          final bool closed = ed != null && ed.isBefore(today);
          final bool future = sd.isAfter(today);
          if (closed) return 0; // 비활성화
          if (!future) return 1; // 활성화
          return 2; // 미래
        }

        entries.sort((a, b) {
          final sa = statusOrder(a);
          final sb = statusOrder(b);
          if (sa != sb) return sa.compareTo(sb);
          // ✅ 활성 항목끼리는 "기간"보다 "요일/시간"이 우선
          if (sa == 1) {
            final cmpDay = a.dayIndex.compareTo(b.dayIndex);
            if (cmpDay != 0) return cmpDay;
            final cmpTime = a.startMinute.compareTo(b.startMinute);
            if (cmpTime != 0) return cmpTime;
            final cmpEnd = a.endMinute.compareTo(b.endMinute);
            if (cmpEnd != 0) return cmpEnd;
            // 같은 요일/시간이면 기간 기준으로 정렬(표시 안정성)
            final aSd = _dateOnly(a.startDate);
            final bSd = _dateOnly(b.startDate);
            final cmpSd = aSd.compareTo(bSd);
            if (cmpSd != 0) return cmpSd;
            final aEd = a.endDate == null ? DateTime(9999, 1, 1) : _dateOnly(a.endDate!);
            final bEd = b.endDate == null ? DateTime(9999, 1, 1) : _dateOnly(b.endDate!);
            final cmpEd = aEd.compareTo(bEd);
            if (cmpEd != 0) return cmpEd;
            return a.key.compareTo(b.key);
          }
          final aSd = _dateOnly(a.startDate);
          final bSd = _dateOnly(b.startDate);
          final cmpSd = aSd.compareTo(bSd);
          if (cmpSd != 0) return cmpSd;
          final aEd = a.endDate == null ? DateTime(9999, 1, 1) : _dateOnly(a.endDate!);
          final bEd = b.endDate == null ? DateTime(9999, 1, 1) : _dateOnly(b.endDate!);
          final cmpEd = aEd.compareTo(bEd);
          if (cmpEd != 0) return cmpEd;
          // 같은 기간 내: 요일 빠른 순(월~일)
          final cmpDay = a.dayIndex.compareTo(b.dayIndex);
          if (cmpDay != 0) return cmpDay;
          // 시간순
          final cmpTime = a.startMinute.compareTo(b.startMinute);
          if (cmpTime != 0) return cmpTime;
          final cmpEnd = a.endMinute.compareTo(b.endMinute);
          if (cmpEnd != 0) return cmpEnd;
          return a.key.compareTo(b.key);
        });

        bool isClosedEntry(_ScheduleEntry it) {
          final ed = it.endDate;
          if (ed == null) return false;
          return _dateOnly(ed).isBefore(today);
        }

        String classNameOfEntry(_ScheduleEntry it) {
          final sid = (it.sessionTypeId ?? '').trim();
          if (sid.isEmpty || sid == '__default_class__') return '기본 수업';
          final c = classById[sid];
          return (c == null || c.name.trim().isEmpty) ? '기본 수업' : c.name.trim();
        }

        String timeRangeOfEntry(_ScheduleEntry it) => '${_hmFromMinutes(it.startMinute)}~${_hmFromMinutes(it.endMinute)}';

        Widget cell(String v, {required int flex, TextAlign align = TextAlign.left, TextStyle? style}) {
          return Expanded(
            flex: flex,
            child: Text(
              v,
              textAlign: align,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style ??
                  const TextStyle(
                    color: text,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          );
        }

        final header = Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF223131),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: border, width: 1),
          ),
          child: Row(
            children: [
              cell('시작', flex: 14),
              cell('끝', flex: 14),
              cell('요일', flex: 6),
              cell('시간', flex: 14),
              cell('수업명', flex: 22),
              cell('마지막 수정', flex: 18),
            ],
          ),
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            header,
            const SizedBox(height: 10),
            Expanded(
              child: Scrollbar(
                child: ListView.separated(
                  itemCount: entries.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final it = entries[i];
                    final closed = isClosedEntry(it);
                    final start = _ymd(_dateOnly(it.startDate));
                    final end = it.endDate == null ? '현재' : _ymd(_dateOnly(it.endDate!));
                    final weekday = _weekday(it.dayIndex);
                    final time = timeRangeOfEntry(it);
                    final cname = classNameOfEntry(it);
                    final modified = '${_ymd(_dateOnly(it.modifiedAt))} ${_hm(it.modifiedAt.toLocal())}';

                    final rowStyle = TextStyle(
                      color: closed ? Colors.white38 : text,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    );

                    return Opacity(
                      opacity: closed ? 0.55 : 1.0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF15171C),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: border, width: 1),
                        ),
                        child: Row(
                          children: [
                            cell(start, flex: 14, style: rowStyle),
                            cell(end, flex: 14, style: rowStyle),
                            cell(weekday, flex: 6, style: rowStyle),
                            cell(time, flex: 14, style: rowStyle),
                            cell(cname, flex: 22, style: rowStyle),
                            cell(modified, flex: 18, style: rowStyle),
                          ],
                        ),
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
  }
}

class _AttendanceHistoryTab extends StatefulWidget {
  final String studentId;
  const _AttendanceHistoryTab({required this.studentId});

  @override
  State<_AttendanceHistoryTab> createState() => _AttendanceHistoryTabState();
}

class _AttendanceHistoryTabState extends State<_AttendanceHistoryTab> {
  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
  static String _ymd(DateTime d) => '${d.year}.${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')}';
  static String _hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  bool _isPurePlanned(AttendanceRecord r) {
    return r.isPlanned == true && !r.isPresent && r.arrivalTime == null;
  }

  SessionOverride? _findOverrideForRecord(List<SessionOverride> ovs, AttendanceRecord r) {
    bool sameMinute(DateTime a, DateTime b) =>
        a.year == b.year && a.month == b.month && a.day == b.day && a.hour == b.hour && a.minute == b.minute;
    for (final o in ovs) {
      if (o.studentId != r.studentId) continue;
      if (o.reason != OverrideReason.makeup) continue;
      if (!(o.overrideType == OverrideType.add || o.overrideType == OverrideType.replace)) continue;
      if (o.status == OverrideStatus.canceled) continue;
      final rep = o.replacementClassDateTime;
      if (rep == null) continue;
      if (sameMinute(rep, r.classDateTime)) return o;
    }
    return null;
  }

  String _classNameOf(AttendanceRecord r, Map<String, ClassInfo> classById) {
    final sid = (r.sessionTypeId ?? '').trim();
    if (sid.isEmpty || sid == '__default_class__') {
      final n = r.className.trim();
      return n.isEmpty ? '기본 수업' : n;
    }
    final c = classById[sid];
    return (c == null || c.name.trim().isEmpty) ? (r.className.trim().isEmpty ? '기본 수업' : r.className.trim()) : c.name.trim();
  }

  Future<void> _connectWalkInToPlanned({
    required AttendanceRecord walkIn,
    required List<AttendanceRecord> candidates,
    required Map<String, ClassInfo> classById,
  }) async {
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('연결할 예정 수업이 없습니다.')),
      );
      return;
    }

    final planned = await showDialog<AttendanceRecord>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF0B1112),
          title: const Text('예정 수업 선택', style: TextStyle(color: Color(0xFFEAF2F2), fontWeight: FontWeight.w900)),
          content: SizedBox(
            width: 720,
            height: 520,
            child: ListView.separated(
              itemCount: candidates.length,
              separatorBuilder: (_, __) => const Divider(color: Color(0xFF223131), height: 1),
              itemBuilder: (context, i) {
                final p = candidates[i];
                final dt = p.classDateTime;
                final title = '${_ymd(_dateOnly(dt))} ${_hm(dt)}~${_hm(p.classEndTime)}';
                final cname = _classNameOf(p, classById);
                return ListTile(
                  title: Text(title, style: const TextStyle(color: Color(0xFFEAF2F2), fontWeight: FontWeight.w800)),
                  subtitle: Text(cname, style: const TextStyle(color: Colors.white60, fontWeight: FontWeight.w600)),
                  onTap: () => Navigator.of(ctx).pop(p),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('취소', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
            ),
          ],
        );
      },
    );
    if (planned == null) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0B1112),
        title: const Text('보강 연결', style: TextStyle(color: Color(0xFFEAF2F2), fontWeight: FontWeight.w900)),
        content: Text(
          '이 추가수업을 선택한 예정 수업과 연결하여 보강(상쇄) 처리할까요?\n\n'
          '연결하면 해당 예정 수업은 제거되고, 이 기록이 보강으로 표시됩니다.',
          style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600, height: 1.35),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('그대로 두기', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('연결', style: TextStyle(color: Color(0xFF33A373), fontWeight: FontWeight.w900)),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      await DataManager.instance.connectWalkInToPlannedAsMakeup(
        walkIn: walkIn,
        planned: planned,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('보강으로 연결되었습니다.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('연결 실패: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    const border = Color(0xFF223131);
    const text = Color(0xFFEAF2F2);

    final listenable = Listenable.merge([
      DataManager.instance.attendanceRecordsNotifier,
      DataManager.instance.sessionOverridesNotifier,
      DataManager.instance.classesRevision,
    ]);

    return AnimatedBuilder(
      animation: listenable,
      builder: (context, _) {
        final now = DateTime.now();
        final today = _dateOnly(now);

        final classById = <String, ClassInfo>{
          for (final c in DataManager.instance.classes) c.id: c,
        };

        final all = DataManager.instance.attendanceRecords
            .where((r) => r.studentId == widget.studentId)
            .toList();
        final ovs = DataManager.instance.sessionOverrides
            .where((o) => o.studentId == widget.studentId)
            .toList();

        // 1) 출석 기록(실기록): planned 여부와 무관하게 실제 등원/하원/출석 정보가 있는 항목
        final attendance = all.where((r) => !_isPurePlanned(r)).toList()
          ..sort((a, b) => b.classDateTime.compareTo(a.classDateTime));

        // 2) 예정 수업: 순수 planned만
        final planned = all.where(_isPurePlanned).toList()
          ..sort((a, b) => a.classDateTime.compareTo(b.classDateTime));

        if (attendance.isEmpty && planned.isEmpty) {
          return const Center(
            child: Text(
              '출석/예정 기록이 없습니다.',
              style: TextStyle(color: Colors.white54, fontSize: 15, fontWeight: FontWeight.w600),
            ),
          );
        }

        Widget cell(String v, {required int flex, TextAlign align = TextAlign.left, TextStyle? style}) {
          return Expanded(
            flex: flex,
            child: Text(
              v,
              textAlign: align,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style ??
                  const TextStyle(
                    color: text,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          );
        }

        Widget headerRow() {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF223131),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: border, width: 1),
            ),
            child: Row(
              children: [
                cell('날짜', flex: 14),
                cell('시간', flex: 16),
                cell('구분', flex: 10),
                cell('등원', flex: 10),
                cell('하원', flex: 10),
                cell('수업명', flex: 26),
                const SizedBox(width: 96), // action slot
              ],
            ),
          );
        }

        Widget badge(String label, Color bg) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w900)),
          );
        }

        Widget rowTile({
          required AttendanceRecord r,
          required bool dimmed,
          required bool isPlannedRow,
        }) {
          final dt = r.classDateTime;
          final dateStr = _ymd(_dateOnly(dt));
          final timeStr = '${_hm(dt)}~${_hm(r.classEndTime)}';
          final cname = _classNameOf(r, classById);

          final ov = _findOverrideForRecord(ovs, r);
          final bool isWalkIn = r.isPlanned == false;
          final bool isMakeup = ov != null && ov.overrideType == OverrideType.replace;
          final bool isAddOverride = ov != null && ov.overrideType == OverrideType.add;

          final statusWidget = () {
            if (isPlannedRow) {
              final past = _dateOnly(dt).isBefore(today);
              return badge(past ? '미출석' : '예정', past ? const Color(0xFF5B4B2B) : const Color(0xFF223131));
            }
            if (isMakeup) return badge('보강', const Color(0xFF1976D2));
            if (isAddOverride) return badge('추가', const Color(0xFF4CAF50));
            if (isWalkIn) return badge('추가수업', const Color(0xFF4CAF50));
            return badge('기록', const Color(0xFF223131));
          }();

          final rowStyle = TextStyle(
            color: dimmed ? Colors.white38 : text,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          );

          final action = () {
            if (isPlannedRow) return const SizedBox(width: 96);
            if (!isWalkIn) return const SizedBox(width: 96);
            if (isMakeup || isAddOverride) return const SizedBox(width: 96);
            return SizedBox(
              width: 96,
              child: TextButton(
                onPressed: () async {
                  final candidates = planned
                      .where((p) => p.id != r.id)
                      .toList();
                  await _connectWalkInToPlanned(walkIn: r, candidates: candidates, classById: classById);
                },
                child: const Text('보강 연결', style: TextStyle(color: Color(0xFF33A373), fontWeight: FontWeight.w900)),
              ),
            );
          }();

          return Opacity(
            opacity: dimmed ? 0.55 : 1.0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF15171C),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: border, width: 1),
              ),
              child: Row(
                children: [
                  cell(dateStr, flex: 14, style: rowStyle),
                  cell(timeStr, flex: 16, style: rowStyle),
                  Expanded(flex: 10, child: Align(alignment: Alignment.centerLeft, child: statusWidget)),
                  cell(r.arrivalTime == null ? '-' : _hm(r.arrivalTime!.toLocal()), flex: 10, style: rowStyle),
                  cell(r.departureTime == null ? '-' : _hm(r.departureTime!.toLocal()), flex: 10, style: rowStyle),
                  cell(cname, flex: 26, style: rowStyle),
                  action,
                ],
              ),
            ),
          );
        }

        final items = <Widget>[];
        if (attendance.isNotEmpty) {
          items.add(const Text('출석 기록', style: TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w900)));
          items.add(const SizedBox(height: 8));
          items.add(headerRow());
          items.add(const SizedBox(height: 10));
          for (final r in attendance) {
            final dimmed = _dateOnly(r.classDateTime).isBefore(today);
            items.add(rowTile(r: r, dimmed: dimmed, isPlannedRow: false));
            items.add(const SizedBox(height: 8));
          }
          items.add(const SizedBox(height: 12));
        }

        if (planned.isNotEmpty) {
          items.add(const Text('예정 수업', style: TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w900)));
          items.add(const SizedBox(height: 8));
          items.add(headerRow());
          items.add(const SizedBox(height: 10));
          for (final r in planned) {
            final dimmed = false;
            items.add(rowTile(r: r, dimmed: dimmed, isPlannedRow: true));
            items.add(const SizedBox(height: 8));
          }
        }

        return Scrollbar(
          child: ListView(
            children: items,
          ),
        );
      },
    );
  }
}

class _ScheduleEntry {
  final String key;
  final String? setId;
  final DateTime startDate;
  final DateTime? endDate;
  final int dayIndex;
  final int startMinute;
  final int endMinute;
  final String? sessionTypeId;
  final DateTime modifiedAt;

  const _ScheduleEntry({
    required this.key,
    required this.setId,
    required this.startDate,
    required this.endDate,
    required this.dayIndex,
    required this.startMinute,
    required this.endMinute,
    required this.sessionTypeId,
    required this.modifiedAt,
  });
}


