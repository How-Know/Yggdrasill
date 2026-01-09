import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../../models/class_info.dart';
import '../../../models/lesson_occurrence.dart';
import '../../../models/student.dart';
import '../../../models/student_time_block.dart';
import '../../../models/attendance_record.dart';
import '../../../models/session_override.dart';
import '../../../services/attendance_service.dart';
import '../../../services/data_manager.dart';
import '../../../utils/attendance_judgement.dart';
import '../../../widgets/pill_tab_selector.dart';
import '../../../widgets/makeup_quick_dialog.dart';

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
  late DateTime _queryStart; // date-only
  late DateTime _queryEnd; // date-only

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  static DateTime _shiftMonthsClamped(DateTime base, int deltaMonths) {
    int y = base.year;
    int m = base.month + deltaMonths;
    while (m <= 0) {
      m += 12;
      y -= 1;
    }
    while (m > 12) {
      m -= 12;
      y += 1;
    }
    final int lastDay = DateUtils.getDaysInMonth(y, m);
    final int d = base.day > lastDay ? lastDay : base.day;
    return DateTime(y, m, d);
  }

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final today = _dateOnly(now);
    // ✅ 기본 조회 기간: 지난달(같은 일자) ~ 이번달(오늘)
    _queryEnd = today;
    _queryStart = _shiftMonthsClamped(today, -1);
  }

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
        // ✅ 요청: 시간기록 다이얼로그 폭 +20%
        width: 1176, // 980 * 1.2
        height: 720,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ✅ 보강관리 다이얼로그처럼: 타이틀 라인에 탭을 함께 배치(폭/높이 축소)
              SizedBox(
                height: 48,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '${widget.student.student.name} · 시간 기록',
                        style: const TextStyle(color: text, fontSize: 18, fontWeight: FontWeight.w900),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Center(
                      child: PillTabSelector(
                        selectedIndex: _tabIndex,
                        tabs: const ['일정 기록', '출석 기록'],
                        onTabSelected: (i) => setState(() => _tabIndex = i),
                        width: 220,
                        height: 36,
                        fontSize: 13,
                        padding: 3,
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
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
                                            '현재 시간표(student_time_blocks)를 기준으로 앞으로 15일치 예정 수업을 다시 생성합니다.\n\n'
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
                                          days: 15,
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
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              // ✅ 조회 기간 드롭다운(기본: 지난달~이번달)
              _QueryRangeDropdown(
                start: _queryStart,
                end: _queryEnd,
                onChanged: (nextStart, nextEnd) {
                  setState(() {
                    _queryStart = nextStart;
                    _queryEnd = nextEnd;
                  });
                },
              ),
              const SizedBox(height: 8),
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
                      ? _ScheduleHistoryTab(
                          studentId: widget.student.student.id,
                          queryStart: _queryStart,
                          queryEnd: _queryEnd,
                        )
                      : _AttendanceHistoryTab(
                          studentId: widget.student.student.id,
                          queryStart: _queryStart,
                          queryEnd: _queryEnd,
                        ),
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
  final DateTime queryStart; // date-only
  final DateTime queryEnd; // date-only
  const _ScheduleHistoryTab({
    required this.studentId,
    required this.queryStart,
    required this.queryEnd,
  });

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
        final rawById = <String, StudentTimeBlock>{
          for (final b in raw) if (b.id.isNotEmpty) b.id: b,
        };

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
          final blockIds = blocks.map((b) => b.id).where((id) => id.trim().isNotEmpty).map((id) => id.trim()).toSet().toList();
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
            blockIds: blockIds,
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

        // ✅ 조회기간 필터는 "과거(닫힘)" 기록에만 적용한다.
        // - 예정(미래 시작)/현재 활성 블록은 항상 보여야 함.
        final qs = _dateOnly(queryStart);
        final qe = _dateOnly(queryEnd);
        bool intersects(DateTime sd, DateTime ed) {
          final a = _dateOnly(sd);
          final b = _dateOnly(ed);
          return !(b.isBefore(qs) || a.isAfter(qe));
        }
        final filtered = <_ScheduleEntry>[];
        for (final it in entries) {
          final sd = _dateOnly(it.startDate);
          final ed = it.endDate == null ? null : _dateOnly(it.endDate!);
          final bool closed = ed != null && ed.isBefore(today);
          final bool future = sd.isAfter(today);
          if (!closed || future) {
            filtered.add(it); // ✅ 활성/미래는 항상 유지
            continue;
          }
          // closed(과거)만 기간 교집합 체크
          if (ed != null && intersects(sd, ed)) {
            filtered.add(it);
          }
        }

        filtered.sort((a, b) {
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

        Widget cell(
          String v, {
          required int flex,
          TextAlign align = TextAlign.left,
          TextStyle? style,
          VoidCallback? onTap,
          String? tooltip,
        }) {
          final String? tip = (tooltip == null || tooltip.trim().isEmpty) ? null : tooltip.trim();
          return Expanded(
            flex: flex,
            child: MouseRegion(
              cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onTap,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                    child: tip == null
                        ? Text(
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
                          )
                        : Tooltip(
                            message: tip,
                            waitDuration: const Duration(milliseconds: 600),
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
                          ),
                  ),
                ),
              ),
            ),
          );
        }

        List<StudentTimeBlock> resolveBlocks(_ScheduleEntry it) {
          final out = <StudentTimeBlock>[];
          for (final id in it.blockIds) {
            final b = rawById[id];
            if (b != null) out.add(b);
          }
          out.sort((a, b) {
            final na = a.number ?? 999999;
            final nb = b.number ?? 999999;
            final cN = na.compareTo(nb);
            if (cN != 0) return cN;
            final c1 = a.startHour.compareTo(b.startHour);
            if (c1 != 0) return c1;
            final c2 = a.startMinute.compareTo(b.startMinute);
            if (c2 != 0) return c2;
            return a.createdAt.compareTo(b.createdAt);
          });
          return out;
        }

        Future<DateTime?> pickDate(DateTime initial) async {
          final picked = await showDatePicker(
            context: context,
            initialDate: initial,
            firstDate: DateTime(2020, 1, 1),
            lastDate: DateTime(DateTime.now().year + 5, 12, 31),
            locale: const Locale('ko', 'KR'),
            builder: (context, child) {
              return Theme(
                data: Theme.of(context).copyWith(
                  colorScheme: const ColorScheme.dark(
                    primary: Color(0xFF1B6B63),
                    onPrimary: Colors.white,
                    surface: Color(0xFF0B1112),
                    onSurface: Color(0xFFEAF2F2),
                  ),
                  dialogBackgroundColor: const Color(0xFF0B1112),
                ),
                child: child!,
              );
            },
          );
          return picked == null ? null : _dateOnly(picked);
        }

        Future<TimeOfDay?> pickTime(TimeOfDay initial) async {
          final picked = await showTimePicker(
            context: context,
            initialTime: initial,
            builder: (context, child) {
              return Theme(
                data: Theme.of(context).copyWith(
                  colorScheme: const ColorScheme.dark(
                    primary: Color(0xFF1B6B63),
                    onPrimary: Colors.white,
                    surface: Color(0xFF0B1112),
                    onSurface: Color(0xFFEAF2F2),
                  ),
                  dialogBackgroundColor: const Color(0xFF0B1112),
                ),
                child: child!,
              );
            },
          );
          return picked;
        }

        int toMin(TimeOfDay t) => t.hour * 60 + t.minute;
        TimeOfDay fromMin(int m) => TimeOfDay(hour: (m ~/ 60) % 24, minute: m % 60);

        Future<void> hardDeleteEntry(_ScheduleEntry it) async {
          final blocks = resolveBlocks(it);
          if (blocks.isEmpty) return;
          final start = _ymd(_dateOnly(it.startDate));
          final end = it.endDate == null ? '현재' : _ymd(_dateOnly(it.endDate!));
          final weekday = _weekday(it.dayIndex);
          final time = timeRangeOfEntry(it);
          final cname = classNameOfEntry(it);
          final ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: const Color(0xFF0B1112),
              title: const Text('일정 하드삭제', style: TextStyle(color: Color(0xFFEAF2F2), fontWeight: FontWeight.w900)),
              content: Text(
                '이 일정(수업 블록)을 서버에서 완전히 삭제합니다.\n\n'
                '- 기간: $start ~ $end\n'
                '- 요일/시간: $weekday  $time\n'
                '- 수업명: $cname\n'
                '- 삭제 블록 수: ${it.blockIds.length}\n\n'
                '정말 삭제할까요? (복구 불가)',
                style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600, height: 1.35),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('취소', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
                ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('삭제', style: TextStyle(color: Color(0xFFB74C4C), fontWeight: FontWeight.w900)),
                ),
              ],
            ),
          );
          if (ok != true) return;

          try {
            // 1) 블록 하드삭제
            await DataManager.instance.hardDeleteStudentTimeBlocks(
              it.blockIds,
              refDate: _dateOnly(DateTime.now()),
            );
            // 2) (set_id 기반) planned 정리/재생성: 우선 해당 set의 순수 planned를 제거하고,
            //    이후 학생 전체 planned를 스케줄 방식으로 재생성하여 session_order를 안정화한다.
            final setId = (it.setId ?? '').trim();
            if (setId.isNotEmpty) {
              await AttendanceService.instance.purgePurePlannedAttendance(
                studentId: studentId,
                setIds: {setId},
              );
              await AttendanceService.instance.purgePlannedBatchSessions(
                studentId: studentId,
                setIds: {setId},
              );
              DataManager.instance.schedulePlannedRegenForStudentSet(
                studentId: studentId,
                setId: setId,
                effectiveStart: it.startDate,
                immediate: false,
              );
            }
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('일정이 삭제되었습니다.')));
            }
          } catch (e) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('삭제 실패: $e')));
            }
          }
        }

        Future<void> editStartDate(_ScheduleEntry it) async {
          final picked = await pickDate(_dateOnly(it.startDate));
          if (picked == null) return;
          final ed = it.endDate == null ? null : _dateOnly(it.endDate!);
          if (ed != null && ed.isBefore(picked)) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('종료일은 시작일보다 빠를 수 없습니다.')));
            return;
          }
          try {
            await DataManager.instance.updateStudentTimeBlocksDateRangeBulk(
              it.blockIds,
              startDate: picked,
              endDate: ed,
              refDate: picked,
            );
            final setId = (it.setId ?? '').trim();
            if (setId.isNotEmpty) {
              DataManager.instance.schedulePlannedRegenForStudentSet(
                studentId: studentId,
                setId: setId,
                effectiveStart: picked,
              );
            }
          } catch (e) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('수정 실패: $e')));
          }
        }

        Future<void> editEndDate(_ScheduleEntry it) async {
          final current = it.endDate == null ? null : _dateOnly(it.endDate!);
          DateTime? next = current;
          final action = await showDialog<String>(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: const Color(0xFF0B1112),
              title: const Text('종료일 수정', style: TextStyle(color: Color(0xFFEAF2F2), fontWeight: FontWeight.w900)),
              content: Text(
                '현재 종료일: ${current == null ? "현재(무기한)" : _ymd(current)}\n\n'
                '어떻게 변경할까요?',
                style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600, height: 1.35),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop('cancel'),
                  child: const Text('취소', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
                ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop('clear'),
                  child: const Text('무기한(현재)', style: TextStyle(color: Color(0xFFEAF2F2), fontWeight: FontWeight.w900)),
                ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop('pick'),
                  child: const Text('날짜 선택', style: TextStyle(color: Color(0xFF33A373), fontWeight: FontWeight.w900)),
                ),
              ],
            ),
          );
          if (action == null || action == 'cancel') return;
          if (action == 'clear') {
            next = null;
          } else if (action == 'pick') {
            final picked = await pickDate(current ?? _dateOnly(DateTime.now()));
            if (picked == null) return;
            next = picked;
          }
          final sd = _dateOnly(it.startDate);
          if (next != null && next!.isBefore(sd)) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('종료일은 시작일보다 빠를 수 없습니다.')));
            return;
          }
          try {
            await DataManager.instance.updateStudentTimeBlocksDateRangeBulk(
              it.blockIds,
              startDate: sd,
              endDate: next,
              refDate: sd,
            );
            final setId = (it.setId ?? '').trim();
            if (setId.isNotEmpty) {
              DataManager.instance.schedulePlannedRegenForStudentSet(
                studentId: studentId,
                setId: setId,
                effectiveStart: sd,
              );
            }
          } catch (e) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('수정 실패: $e')));
          }
        }

        Future<void> editClassName(_ScheduleEntry it) async {
          final classes = DataManager.instance.classes.where((c) => c.id.trim().isNotEmpty).toList();
          final selected = await showDialog<String?>(
            context: context,
            builder: (ctx) {
              return AlertDialog(
                backgroundColor: const Color(0xFF0B1112),
                title: const Text('수업명 변경', style: TextStyle(color: Color(0xFFEAF2F2), fontWeight: FontWeight.w900)),
                content: SizedBox(
                  width: 520,
                  height: 520,
                  child: ListView.separated(
                    itemCount: classes.length + 1,
                    separatorBuilder: (_, __) => const Divider(color: Color(0xFF223131), height: 1),
                    itemBuilder: (context, i) {
                      if (i == 0) {
                        return ListTile(
                          title: const Text('기본 수업', style: TextStyle(color: Color(0xFFEAF2F2), fontWeight: FontWeight.w800)),
                          subtitle: const Text('session_type_id = null', style: TextStyle(color: Colors.white54, fontWeight: FontWeight.w600)),
                          onTap: () => Navigator.of(ctx).pop(''),
                        );
                      }
                      final c = classes[i - 1];
                      return ListTile(
                        title: Text(c.name, style: const TextStyle(color: Color(0xFFEAF2F2), fontWeight: FontWeight.w800)),
                        subtitle: Text(c.id, style: const TextStyle(color: Colors.white54, fontWeight: FontWeight.w600)),
                        onTap: () => Navigator.of(ctx).pop(c.id),
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
          if (selected == null) return;
          final nextSid = selected.trim().isEmpty ? null : selected.trim();
          try {
            await DataManager.instance.updateStudentTimeBlocksSessionTypeIdBulk(
              it.blockIds,
              sessionTypeId: nextSid,
              refDate: _dateOnly(DateTime.now()),
            );
            final setId = (it.setId ?? '').trim();
            if (setId.isNotEmpty) {
              DataManager.instance.schedulePlannedRegenForStudentSet(
                studentId: studentId,
                setId: setId,
                effectiveStart: it.startDate,
              );
            }
          } catch (e) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('수정 실패: $e')));
          }
        }

        Future<void> editTimeRange(_ScheduleEntry it) async {
          final blocks = resolveBlocks(it);
          if (blocks.isEmpty) return;

          final int curStart = it.startMinute;
          final int curEnd = it.endMinute;

          TimeOfDay startT = fromMin(curStart);
          TimeOfDay endT = fromMin(curEnd);
          final picked = await showDialog<bool>(
            context: context,
            builder: (ctx) {
              return StatefulBuilder(builder: (ctx, setState) {
                String fmt(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
                return AlertDialog(
                  backgroundColor: const Color(0xFF0B1112),
                  title: const Text('시간 변경', style: TextStyle(color: Color(0xFFEAF2F2), fontWeight: FontWeight.w900)),
                  content: SizedBox(
                    width: 420,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('시간 범위를 선택하세요.', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () async {
                                  final p = await pickTime(startT);
                                  if (p == null) return;
                                  setState(() => startT = p);
                                },
                                child: Text('시작: ${fmt(startT)}'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () async {
                                  final p = await pickTime(endT);
                                  if (p == null) return;
                                  setState(() => endT = p);
                                },
                                child: Text('끝: ${fmt(endT)}'),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '현재 row는 30분 블록 묶음(set_id) 기준입니다.\n'
                          '필요 시 블록 개수를 자동으로 늘리거나 줄입니다.',
                          style: const TextStyle(color: Colors.white54, fontWeight: FontWeight.w600, height: 1.35),
                        ),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: const Text('취소', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      child: const Text('수정', style: TextStyle(color: Color(0xFF33A373), fontWeight: FontWeight.w900)),
                    ),
                  ],
                );
              });
            },
          );
          if (picked != true) return;

          final int newStartMin = toMin(startT);
          final int newEndMin = toMin(endT);
          if (newEndMin <= newStartMin) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('끝 시간은 시작 시간보다 늦어야 합니다.')));
            return;
          }

          // 단일(legacy) 블록이면 duration만 조정해서 처리
          final setId = (it.setId ?? '').trim();
          if (setId.isEmpty) {
            final b = blocks.first;
            try {
              await DataManager.instance.updateStudentTimeBlockSchedule(
                b.id,
                dayIndex: b.dayIndex,
                startHour: newStartMin ~/ 60,
                startMinute: newStartMin % 60,
                durationMinutes: (newEndMin - newStartMin),
                number: b.number,
                refDate: _dateOnly(DateTime.now()),
              );
            } catch (e) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('수정 실패: $e')));
            }
            return;
          }

          // set_id(30분 블록 묶음): (1) 필요한 블록 수 계산 → (2) 기존 블록 update → (3) 초과분 하드삭제 or 부족분 추가
          const int blockMinutes = 30;
          final total = newEndMin - newStartMin;
          final full = total ~/ blockMinutes;
          final rem = total % blockMinutes;
          final durations = <int>[
            for (int i = 0; i < full; i++) blockMinutes,
            if (rem > 0) rem,
          ];
          if (durations.isEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('유효하지 않은 시간 범위입니다.')));
            return;
          }

          // 충돌 체크(간단): 같은 학생/요일에서 기간이 겹치는 다른 블록과 시간 겹침이 있으면 막는다.
          final sd = _dateOnly(it.startDate);
          final ed = it.endDate == null ? null : _dateOnly(it.endDate!);
          bool rangesOverlap(DateTime a1, DateTime? a2, DateTime b1, DateTime? b2) {
            final aEnd = a2 ?? DateTime(9999, 12, 31);
            final bEnd = b2 ?? DateTime(9999, 12, 31);
            return !(aEnd.isBefore(b1) || bEnd.isBefore(a1));
          }
          final otherBlocks = raw.where((b) => !it.blockIds.contains(b.id) && b.dayIndex == it.dayIndex).toList();
          for (final ob in otherBlocks) {
            final osd = _dateOnly(ob.startDate);
            final oed = ob.endDate == null ? null : _dateOnly(ob.endDate!);
            if (!rangesOverlap(sd, ed, osd, oed)) continue;
            final oStart = ob.startHour * 60 + ob.startMinute;
            final oEnd = oStart + ob.duration.inMinutes;
            final overlap = newStartMin < oEnd && oStart < newEndMin;
            if (overlap) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('다른 일정과 시간이 겹칩니다.')));
              return;
            }
          }

          final old = List<StudentTimeBlock>.from(blocks);
          old.sort((a, b) {
            final na = a.number ?? 999999;
            final nb = b.number ?? 999999;
            final cN = na.compareTo(nb);
            if (cN != 0) return cN;
            final aMin = a.startHour * 60 + a.startMinute;
            final bMin = b.startHour * 60 + b.startMinute;
            return aMin.compareTo(bMin);
          });

          final int keepN = (old.length < durations.length) ? old.length : durations.length;
          final toDelete = old.length > durations.length ? old.sublist(durations.length) : const <StudentTimeBlock>[];
          final toAddCount = durations.length > old.length ? durations.length - old.length : 0;

          // 롤백용(서버/로컬) 원본/추가된 id 추적
          final originalById = <String, StudentTimeBlock>{};
          final addedIds = <String>[];

          try {
            int cur = newStartMin;

            // 1) 기존 블록 update (publish 지연)
            for (int i = 0; i < keepN; i++) {
              final b = old[i];
              originalById[b.id] = b;
              final dur = durations[i];
              await DataManager.instance.updateStudentTimeBlockSchedule(
                b.id,
                dayIndex: b.dayIndex,
                startHour: cur ~/ 60,
                startMinute: cur % 60,
                durationMinutes: dur,
                number: i + 1,
                publish: false,
                refDate: sd,
              );
              cur += dur;
            }

            // 2) 부족분 추가 (기존 블록과 일시적으로 겹칠 수 있으므로 overlap check는 skip)
            if (toAddCount > 0) {
              final base = old.isNotEmpty ? old.first : blocks.first;
              final addBlocks = <StudentTimeBlock>[];
              for (int i = keepN; i < durations.length; i++) {
                final dur = durations[i];
                final id = const Uuid().v4();
                addedIds.add(id);
                addBlocks.add(
                  StudentTimeBlock(
                    id: id,
                    studentId: base.studentId,
                    dayIndex: base.dayIndex,
                    startHour: cur ~/ 60,
                    startMinute: cur % 60,
                    duration: Duration(minutes: dur),
                    createdAt: DateTime.now(),
                    startDate: sd,
                    endDate: ed,
                    setId: setId,
                    number: i + 1,
                    sessionTypeId: base.sessionTypeId,
                    weeklyOrder: base.weeklyOrder,
                  ),
                );
                cur += dur;
              }
              await DataManager.instance.bulkAddStudentTimeBlocks(
                addBlocks,
                immediate: true,
                injectLocal: true,
                skipOverlapCheck: true,
              );
            }

            // 3) 초과분 하드삭제(마지막에 수행: 실패 시 데이터 손실 최소화)
            if (toDelete.isNotEmpty) {
              await DataManager.instance.hardDeleteStudentTimeBlocks(
                toDelete.map((b) => b.id).toList(),
                publish: false,
                refDate: sd,
              );
            }

            // 4) publish(한 번)
            DataManager.instance.applyStudentTimeBlocksOptimistic(
              List<StudentTimeBlock>.from(DataManager.instance.studentTimeBlocks),
              refDate: sd,
            );

            // 5) planned 재생성 스케줄
            DataManager.instance.schedulePlannedRegenForStudentSet(
              studentId: studentId,
              setId: setId,
              effectiveStart: sd,
              immediate: false,
            );
          } catch (e) {
            // best-effort rollback: (1) 추가된 블록 삭제 (2) 수정된 기존 블록 원복
            try {
              if (addedIds.isNotEmpty) {
                await DataManager.instance.hardDeleteStudentTimeBlocks(
                  addedIds,
                  publish: false,
                  refDate: sd,
                );
              }
            } catch (_) {}
            try {
              for (final b in originalById.values) {
                await DataManager.instance.updateStudentTimeBlockSchedule(
                  b.id,
                  dayIndex: b.dayIndex,
                  startHour: b.startHour,
                  startMinute: b.startMinute,
                  durationMinutes: b.duration.inMinutes,
                  number: b.number,
                  publish: false,
                  refDate: sd,
                  touchModifiedAt: false,
                );
              }
            } catch (_) {}
            try {
              DataManager.instance.applyStudentTimeBlocksOptimistic(
                List<StudentTimeBlock>.from(DataManager.instance.studentTimeBlocks),
                refDate: sd,
              );
            } catch (_) {}
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('수정 실패: $e')));
          }
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
              cell('마지막 수정', flex: 18, align: TextAlign.left),
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
                  itemCount: filtered.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final it = filtered[i];
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
                            cell(
                              start,
                              flex: 14,
                              style: rowStyle,
                              onTap: () => editStartDate(it),
                              tooltip: '클릭하여 시작일 수정',
                            ),
                            cell(
                              end,
                              flex: 14,
                              style: rowStyle,
                              onTap: () => editEndDate(it),
                              tooltip: '클릭하여 종료일 수정',
                            ),
                            cell(weekday, flex: 6, style: rowStyle),
                            cell(
                              time,
                              flex: 14,
                              style: rowStyle,
                              onTap: () => editTimeRange(it),
                              tooltip: '클릭하여 시간 수정',
                            ),
                            cell(
                              cname,
                              flex: 22,
                              style: rowStyle,
                              onTap: () => editClassName(it),
                              tooltip: '클릭하여 수업명(연결) 수정',
                            ),
                            Expanded(
                              flex: 18,
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      modified,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: rowStyle,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Tooltip(
                                    message: '하드삭제(서버 삭제)',
                                    child: IconButton(
                                      onPressed: () => hardDeleteEntry(it),
                                      icon: const Icon(Icons.delete_forever, color: Color(0xFFB74C4C), size: 18),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                      splashRadius: 18,
                                    ),
                                  ),
                                ],
                              ),
                            ),
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
  final DateTime queryStart; // date-only
  final DateTime queryEnd; // date-only
  const _AttendanceHistoryTab({
    required this.studentId,
    required this.queryStart,
    required this.queryEnd,
  });

  @override
  State<_AttendanceHistoryTab> createState() => _AttendanceHistoryTabState();
}

class _AttendanceHistoryTabState extends State<_AttendanceHistoryTab> {
  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
  static String _ymd(DateTime d) => '${d.year}.${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')}';
  static String _hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  static String _minuteKey(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final mo = dt.month.toString().padLeft(2, '0');
    final da = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final mi = dt.minute.toString().padLeft(2, '0');
    return '$y-$mo-$da-$h-$mi';
  }
  static String _weekdayShort(DateTime d) {
    // DateTime.weekday: Mon=1 ... Sun=7
    switch (d.weekday) {
      case DateTime.monday:
        return '월';
      case DateTime.tuesday:
        return '화';
      case DateTime.wednesday:
        return '수';
      case DateTime.thursday:
        return '목';
      case DateTime.friday:
        return '금';
      case DateTime.saturday:
        return '토';
      case DateTime.sunday:
        return '일';
      default:
        return '';
    }
  }

  static String _ymdWithWeekday(DateTime d) {
    final dd = _dateOnly(d);
    return '${_ymd(dd)} (${_weekdayShort(dd)})';
  }

  String? _expandedMakeupKey; // 보강(대조) 카드 펼침 상태
  bool _autoFixOrderTriggered = false;
  bool _autoFixOrderRunning = false;
  bool _cycleDebugPrinted = false;
  final GlobalKey _todayDividerKey = GlobalKey(debugLabel: 'attendanceTodayDivider');
  final ScrollController _scrollController = ScrollController();
  bool _didCenterTodayDivider = false;
  bool _centeringTodayDividerPending = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  static String _rowKey(AttendanceRecord r) {
    final id = (r.id ?? '').trim();
    if (id.isNotEmpty) return id;
    final dt = r.classDateTime;
    final m = DateTime(dt.year, dt.month, dt.day, dt.hour, dt.minute);
    return '${r.studentId}|${m.toIso8601String()}';
  }

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
        title: const Text('예정 연결', style: TextStyle(color: Color(0xFFEAF2F2), fontWeight: FontWeight.w900)),
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
      DataManager.instance.studentPaymentInfoRevision,
    ]);

    return AnimatedBuilder(
      animation: listenable,
      builder: (context, _) {
        final now = DateTime.now();
        final today = _dateOnly(now);
        final qs = _dateOnly(widget.queryStart);
        final qe = _dateOnly(widget.queryEnd);

        final classById = <String, ClassInfo>{
          for (final c in DataManager.instance.classes) c.id: c,
        };
        final latenessThresholdMinutes =
            DataManager.instance.getStudentPaymentInfo(widget.studentId)?.latenessThreshold ?? 10;

        final all = DataManager.instance.attendanceRecords
            .where((r) => r.studentId == widget.studentId)
            .toList();
        final ovs = DataManager.instance.sessionOverrides
            .where((o) => o.studentId == widget.studentId)
            .toList();

        // ✅ 조회기간 필터: "출석/과거" 영역에만 적용
        // - 예정 수업(오늘 포함 미래)은 필터 영향 X (짧은 기간을 선택해도 앞으로의 일정은 항상 보여야 함)
        bool inRange(DateTime dt) {
          final d = _dateOnly(dt);
          return !d.isBefore(qs) && !d.isAfter(qe);
        }

        // 순수 예정(planned) 전체 (추가수업의 '예정 연결' 후보로도 사용)
        final purePlanned = all.where(_isPurePlanned).toList()
          ..sort((a, b) => a.classDateTime.compareTo(b.classDateTime));

        // 1) 실제 출석 기록(실기록): planned 여부와 무관하게 등/하원/출석 정보가 있는 항목
        //    - 조회기간 필터 적용
        final actual = all.where((r) => !_isPurePlanned(r) && inRange(r.classDateTime)).toList();

        // 2) 예정 수업(순수 planned) 중 "오늘 이전"은 출석 리스트(과거 영역)에 포함
        //    - 조회기간 필터 적용
        final plannedPast = purePlanned
            .where((r) => _dateOnly(r.classDateTime).isBefore(today) && inRange(r.classDateTime))
            .toList();

        // 3) 예정 수업(오늘 포함 미래)은 아래(미래 영역)로 유지
        //    - 조회기간 필터 미적용
        final plannedFuture =
            purePlanned.where((r) => !_dateOnly(r.classDateTime).isBefore(today)).toList()
              ..sort((a, b) => a.classDateTime.compareTo(b.classDateTime));

        // 사용자에게는 "하나의 리스트"처럼 보이도록 병합
        // - 과거 영역: 실제 출석 + 오늘 이전 예정(미출석)
        // - 미래 영역: 오늘 포함 예정
        final mergedPast = <AttendanceRecord>[...actual, ...plannedPast]
          ..sort((a, b) => a.classDateTime.compareTo(b.classDateTime));

        if (mergedPast.isEmpty && plannedFuture.isEmpty) {
          return const Center(
            child: Text(
              '출석/예정 기록이 없습니다.',
              style: TextStyle(color: Colors.white54, fontSize: 15, fontWeight: FontWeight.w600),
            ),
          );
        }

        // ✅ 디버그 출력(1회):
        // - 저장된 cycle/session_order
        // - occurrence(원본회차) 기반 값
        // - "현재 스케줄(시간순+set_id)"로 계산한 기대값
        // 을 비교해서, 어느 소스가 꼬임의 원인인지 확인한다.
        void debugPrintCycleOrderOnce() {
          if (_cycleDebugPrinted) return;
          _cycleDebugPrinted = true;

          final allShown = <AttendanceRecord>[...mergedPast, ...plannedFuture]
            ..sort((a, b) => a.classDateTime.compareTo(b.classDateTime));
          if (allShown.isEmpty) return;

          final occById = <String, LessonOccurrence>{
            for (final o in AttendanceService.instance.lessonOccurrences) o.id: o,
          };

          // replace(대체)는 원본 시간 기준으로 회차를 보려면 override 맵이 필요
          final Map<String, DateTime> origByRepMinute = {};
          for (final o in ovs) {
            if (o.overrideType != OverrideType.replace) continue;
            if (o.status == OverrideStatus.canceled) continue;
            final rep = o.replacementClassDateTime;
            final orig = o.originalClassDateTime;
            if (rep == null || orig == null) continue;
            origByRepMinute[_minuteKey(rep.toLocal())] = orig.toLocal();
          }

          // cycle별 기대 orderMap
          final cycles = <int>{
            for (final r in allShown)
              if (r.cycle != null && r.cycle! > 0) r.cycle!,
          }.toList()
            ..sort();
          final Map<int, Map<String, int>> orderMapByCycle = {
            for (final c in cycles)
              c: AttendanceService.instance.debugBuildSessionOrderMapForStudentCycle(
                studentId: widget.studentId,
                cycle: c,
              ),
          };

          print('[CYCLEDBG] student=${widget.studentId} rows=${allShown.length} cycles=$cycles');
          for (final c in cycles) {
            print('[CYCLEDBG]  cycle=$c orderMapSize=${orderMapByCycle[c]?.length ?? 0}');
          }

          // dup check (cycle/session_order)
          final Map<String, List<AttendanceRecord>> dup = {};
          for (final r in allShown) {
            final c = r.cycle;
            final o = r.sessionOrder;
            if (c == null || o == null) continue;
            dup.putIfAbsent('$c|$o', () => <AttendanceRecord>[]).add(r);
          }
          final dupKeys = dup.entries.where((e) => e.value.length > 1).toList();
          if (dupKeys.isNotEmpty) {
            print('[CYCLEDBG] duplicates=${dupKeys.length}');
            for (final e in dupKeys.take(12)) {
              final parts = e.key.split('|');
              print('[CYCLEDBG][DUP] key=${e.key} (cycle=${parts[0]} order=${parts[1]}) count=${e.value.length}');
              for (final r in e.value.take(4)) {
                final cname = _classNameOf(r, classById);
                print(
                  '[CYCLEDBG][DUP]  dt=${r.classDateTime} set=${r.setId} class="$cname" occ=${r.occurrenceId} planned=${r.isPlanned}',
                );
              }
            }
          }

          // mismatch check
          int printed = 0;
          for (final r in allShown) {
            final setId = (r.setId ?? '').trim();
            if (setId.isEmpty) continue;
            final storedCycle = r.cycle;
            final storedOrder = r.sessionOrder;
            if (storedCycle == null || storedCycle <= 0) continue;

            final occId = (r.occurrenceId ?? '').trim();
            final occ = occId.isEmpty ? null : occById[occId];
            final dtLocal = r.classDateTime.toLocal();
            final effectiveLocal = origByRepMinute[_minuteKey(dtLocal)] ?? (occ?.originalClassDateTime ?? dtLocal);

            final map = orderMapByCycle[storedCycle];
            final expKey = AttendanceService.instance.debugSessionKeyForOrder(setId: setId, startLocal: effectiveLocal);
            final expectedOrder = map == null ? null : map[expKey];
            final expectedCycleByDue = AttendanceService.instance.debugResolveCycleByDueDate(widget.studentId, effectiveLocal);

            final bool mismatch =
                (expectedCycleByDue != null && expectedCycleByDue > 0 && expectedCycleByDue != storedCycle) ||
                (expectedOrder != null && storedOrder != null && expectedOrder != storedOrder) ||
                (expectedOrder == null && storedOrder != null);
            if (!mismatch) continue;

            printed++;
            if (printed > 40) break;
            final cname = _classNameOf(r, classById);
            print(
              '[CYCLEDBG][ROW] dt=${r.classDateTime} set=$setId class="$cname" '
              'stored=${storedCycle}/${storedOrder ?? "-"} dueCycle=${expectedCycleByDue ?? "-"} '
              'expOrder=${expectedOrder ?? "-"} expKey=$expKey '
              'occ=${occId.isEmpty ? "-" : occId} occKind=${occ?.kind ?? "-"} occOrder=${occ?.cycle}/${occ?.sessionOrder ?? "-"} '
              'planned=${r.isPlanned} present=${r.isPresent}',
            );
          }
          if (printed == 0) {
            print('[CYCLEDBG] no mismatches detected (within printed rule)');
          }
        }
        debugPrintCycleOrderOnce();

        // ✅ 자동 회차 정리(경량):
        // "같은 날 다른 set_id 수업" 등으로 cycle/session_order가 중복/역순으로 보이면,
        // 현재 로드된 범위 내에서만 재계산하여 서버에 업데이트한다.
        void maybeAutoFixOrder() {
          if (_autoFixOrderTriggered || _autoFixOrderRunning) return;
          final allShown = <AttendanceRecord>[...mergedPast, ...plannedFuture];
          if (allShown.isEmpty) return;

          // 1) 중복(cycle/sessionOrder 동일) 탐지
          final Map<String, int> counts = {};
          for (final r in allShown) {
            final c = r.cycle;
            final o = r.sessionOrder;
            if (c == null || o == null) continue;
            final k = '$c|$o';
            counts[k] = (counts[k] ?? 0) + 1;
          }
          final hasDup = counts.values.any((v) => v > 1);

          // 2) 시간순 정렬인데 회차가 역전되는 케이스 탐지
          bool hasReverse = false;
          final withOrder = allShown.where((r) => r.cycle != null && r.sessionOrder != null).toList()
            ..sort((a, b) => a.classDateTime.compareTo(b.classDateTime));
          for (int i = 1; i < withOrder.length; i++) {
            final prev = withOrder[i - 1];
            final cur = withOrder[i];
            if (prev.cycle != cur.cycle) continue;
            if (prev.sessionOrder == null || cur.sessionOrder == null) continue;
            if (prev.sessionOrder! > cur.sessionOrder!) {
              hasReverse = true;
              break;
            }
          }

          if (!hasDup && !hasReverse) return;

          _autoFixOrderTriggered = true;
          _autoFixOrderRunning = true;

          // 표시 중인 최소~최대 범위만 업데이트(여유 1일)
          DateTime minDt = allShown.first.classDateTime;
          DateTime maxDt = allShown.first.classDateTime;
          for (final r in allShown) {
            final d = r.classDateTime;
            if (d.isBefore(minDt)) minDt = d;
            if (d.isAfter(maxDt)) maxDt = d;
          }
          final from = DateTime(minDt.year, minDt.month, minDt.day).subtract(const Duration(days: 1));
          final to = DateTime(maxDt.year, maxDt.month, maxDt.day).add(const Duration(days: 2));

          WidgetsBinding.instance.addPostFrameCallback((_) async {
            if (!mounted) return;
            try {
              final updated = await AttendanceService.instance.fixCycleSessionOrderForStudentInLoadedRange(
                studentId: widget.studentId,
                fromInclusive: from,
                toExclusive: to,
              );
              if (!mounted) return;
              if (updated > 0) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('회차를 정리했습니다. (${updated}건)')),
                );
              }
            } finally {
              if (mounted) {
                setState(() {
                  _autoFixOrderRunning = false;
                });
              }
            }
          });
        }
        maybeAutoFixOrder();

        Future<DateTime?> pickDate(DateTime initial) async {
          final picked = await showDatePicker(
            context: context,
            initialDate: initial,
            firstDate: DateTime(2000),
            lastDate: DateTime(2100),
            locale: const Locale('ko', 'KR'),
            builder: (context, child) {
              return Theme(
                data: Theme.of(context).copyWith(
                  colorScheme: const ColorScheme.dark(
                    primary: Color(0xFF1B6B63),
                    onPrimary: Colors.white,
                    surface: Color(0xFF0B1112),
                    onSurface: Color(0xFFEAF2F2),
                  ),
                  dialogBackgroundColor: const Color(0xFF0B1112),
                ),
                child: child!,
              );
            },
          );
          return picked;
        }

        Future<TimeOfDay?> pickTime(TimeOfDay initial) async {
          final picked = await showTimePicker(
            context: context,
            initialTime: initial,
            helpText: '시간 선택',
            builder: (context, child) {
              return Theme(
                data: Theme.of(context).copyWith(
                  colorScheme: const ColorScheme.dark(
                    primary: Color(0xFF1B6B63),
                    onPrimary: Colors.white,
                    surface: Color(0xFF0B1112),
                    onSurface: Color(0xFFEAF2F2),
                  ),
                  dialogBackgroundColor: const Color(0xFF0B1112),
                ),
                child: child!,
              );
            },
          );
          return picked;
        }

        Future<void> updateAttendanceRecordWithSnack(AttendanceRecord next) async {
          final rid = (next.id ?? '').trim();
          if (rid.isEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('수정할 기록 ID가 없습니다.')));
            return;
          }
          try {
            await AttendanceService.instance.updateAttendanceRecord(next.copyWith(updatedAt: DateTime.now()));
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('수정되었습니다.')));
          } on StateError catch (e) {
            if (!context.mounted) return;
            if (e.message == 'CONFLICT_ATTENDANCE_VERSION') {
              await AttendanceService.instance.loadAttendanceRecords();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('다른 기기에서 먼저 수정했습니다. 새로고침 후 다시 시도하세요.')),
              );
              return;
            }
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('수정 실패: $e')));
          } catch (e) {
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('수정 실패: $e')));
          }
        }

        Future<void> editDateOf(AttendanceRecord r) async {
          final picked = await pickDate(_dateOnly(r.classDateTime));
          if (picked == null) return;
          var dur = r.classEndTime.difference(r.classDateTime);
          if (dur.inMinutes <= 0) {
            dur = Duration(minutes: DataManager.instance.academySettings.lessonDuration);
          }
          final nextStart = DateTime(picked.year, picked.month, picked.day, r.classDateTime.hour, r.classDateTime.minute);
          final nextEnd = nextStart.add(dur);
          DateTime? shiftToDay(DateTime? t) =>
              t == null ? null : DateTime(picked.year, picked.month, picked.day, t.hour, t.minute);
          final next = r.copyWith(
            classDateTime: nextStart,
            classEndTime: nextEnd,
            arrivalTime: shiftToDay(r.arrivalTime),
            departureTime: shiftToDay(r.departureTime),
          );
          await updateAttendanceRecordWithSnack(next);
        }

        Future<void> editTimeRangeOf(AttendanceRecord r) async {
          TimeOfDay startT = TimeOfDay.fromDateTime(r.classDateTime);
          TimeOfDay endT = TimeOfDay.fromDateTime(r.classEndTime);

          int toMin(TimeOfDay t) => t.hour * 60 + t.minute;
          String fmt(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

          final ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => StatefulBuilder(
              builder: (ctx, setState) => AlertDialog(
                backgroundColor: const Color(0xFF0B1112),
                title: const Text('시간 수정', style: TextStyle(color: Color(0xFFEAF2F2), fontWeight: FontWeight.w900)),
                content: SizedBox(
                  width: 420,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('수업 시간 범위를 선택하세요.', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () async {
                                final p = await pickTime(startT);
                                if (p == null) return;
                                setState(() => startT = p);
                              },
                              child: Text('시작: ${fmt(startT)}'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () async {
                                final p = await pickTime(endT);
                                if (p == null) return;
                                setState(() => endT = p);
                              },
                              child: Text('끝: ${fmt(endT)}'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: const Text('취소', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    child: const Text('수정', style: TextStyle(color: Color(0xFF33A373), fontWeight: FontWeight.w900)),
                  ),
                ],
              ),
            ),
          );
          if (ok != true) return;

          final startMin = toMin(startT);
          final endMin = toMin(endT);
          if (endMin <= startMin) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('끝 시간은 시작 시간보다 늦어야 합니다.')));
            return;
          }
          final base = _dateOnly(r.classDateTime);
          final nextStart = DateTime(base.year, base.month, base.day, startT.hour, startT.minute);
          final nextEnd = DateTime(base.year, base.month, base.day, endT.hour, endT.minute);
          final next = r.copyWith(classDateTime: nextStart, classEndTime: nextEnd);
          await updateAttendanceRecordWithSnack(next);
        }

        Future<void> editArrivalOf(AttendanceRecord r) async {
          final action = await showDialog<String>(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: const Color(0xFF0B1112),
              title: const Text('등원 시간 수정', style: TextStyle(color: Color(0xFFEAF2F2), fontWeight: FontWeight.w900)),
              content: const Text(
                '어떻게 변경할까요?',
                style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600, height: 1.35),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop('cancel'),
                  child: const Text('취소', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
                ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop('clear'),
                  child: const Text('없음', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w900)),
                ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop('pick'),
                  child: const Text('시간 선택', style: TextStyle(color: Color(0xFF33A373), fontWeight: FontWeight.w900)),
                ),
              ],
            ),
          );
          if (action == null || action == 'cancel') return;

          DateTime? nextArrival;
          if (action == 'pick') {
            final initial = r.arrivalTime == null ? TimeOfDay.fromDateTime(r.classDateTime) : TimeOfDay.fromDateTime(r.arrivalTime!);
            final picked = await pickTime(initial);
            if (picked == null) return;
            final base = _dateOnly(r.classDateTime);
            nextArrival = DateTime(base.year, base.month, base.day, picked.hour, picked.minute);
          } else if (action == 'clear') {
            nextArrival = null;
          }

          final next = r.copyWith(
            arrivalTime: nextArrival,
            // 시간 기록이 들어가면 출석으로 간주하는 것이 자연스럽다.
            isPresent: (nextArrival != null) ? true : r.isPresent,
          );
          await updateAttendanceRecordWithSnack(next);
        }

        Future<void> editDepartureOf(AttendanceRecord r) async {
          final action = await showDialog<String>(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: const Color(0xFF0B1112),
              title: const Text('하원 시간 수정', style: TextStyle(color: Color(0xFFEAF2F2), fontWeight: FontWeight.w900)),
              content: const Text(
                '어떻게 변경할까요?',
                style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600, height: 1.35),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop('cancel'),
                  child: const Text('취소', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
                ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop('clear'),
                  child: const Text('없음', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w900)),
                ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop('pick'),
                  child: const Text('시간 선택', style: TextStyle(color: Color(0xFF33A373), fontWeight: FontWeight.w900)),
                ),
              ],
            ),
          );
          if (action == null || action == 'cancel') return;

          DateTime? nextDeparture;
          if (action == 'pick') {
            final initial = r.departureTime == null ? TimeOfDay.fromDateTime(r.classEndTime) : TimeOfDay.fromDateTime(r.departureTime!);
            final picked = await pickTime(initial);
            if (picked == null) return;
            final base = _dateOnly(r.classDateTime);
            nextDeparture = DateTime(base.year, base.month, base.day, picked.hour, picked.minute);
          } else if (action == 'clear') {
            nextDeparture = null;
          }

          final next = r.copyWith(
            departureTime: nextDeparture,
            isPresent: (nextDeparture != null) ? true : r.isPresent,
          );
          await updateAttendanceRecordWithSnack(next);
        }

        Future<void> editClassNameOf(AttendanceRecord r) async {
          final classes = DataManager.instance.classes.where((c) => c.id.trim().isNotEmpty).toList();
          final selected = await showDialog<String?>(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: const Color(0xFF0B1112),
              title: const Text('수업명 변경', style: TextStyle(color: Color(0xFFEAF2F2), fontWeight: FontWeight.w900)),
              content: SizedBox(
                width: 520,
                height: 520,
                child: ListView.separated(
                  itemCount: classes.length + 1,
                  separatorBuilder: (_, __) => const Divider(color: Color(0xFF223131), height: 1),
                  itemBuilder: (context, i) {
                    if (i == 0) {
                      return ListTile(
                        title: const Text('기본 수업', style: TextStyle(color: Color(0xFFEAF2F2), fontWeight: FontWeight.w800)),
                        subtitle: const Text('session_type_id = null', style: TextStyle(color: Colors.white54, fontWeight: FontWeight.w600)),
                        onTap: () => Navigator.of(ctx).pop(''),
                      );
                    }
                    final c = classes[i - 1];
                    return ListTile(
                      title: Text(c.name, style: const TextStyle(color: Color(0xFFEAF2F2), fontWeight: FontWeight.w800)),
                      subtitle: Text(c.id, style: const TextStyle(color: Colors.white54, fontWeight: FontWeight.w600)),
                      onTap: () => Navigator.of(ctx).pop(c.id),
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
            ),
          );
          if (selected == null) return;
          final nextSid = selected.trim().isEmpty ? null : selected.trim();
          final nextName = () {
            if (nextSid == null) return '기본 수업';
            for (final c in classes) {
              if (c.id == nextSid) return c.name.trim().isEmpty ? '수업' : c.name.trim();
            }
            return r.className.trim().isEmpty ? '수업' : r.className.trim();
          }();

          final next = r.copyWith(
            sessionTypeId: nextSid,
            className: nextName,
          );
          await updateAttendanceRecordWithSnack(next);
        }

        Widget cell(
          String v, {
          required int flex,
          TextAlign align = TextAlign.center,
          TextStyle? style,
          EdgeInsetsGeometry? padding,
          VoidCallback? onTap,
          String? tooltip,
        }) {
          Widget child = Text(
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
          );
          if (padding != null) {
            child = Padding(padding: padding, child: child);
          }
          if (onTap != null) {
            child = Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: child,
                ),
              ),
            );
            if (tooltip != null && tooltip.trim().isNotEmpty) {
              child = Tooltip(message: tooltip.trim(), child: child);
            }
          }
          return Expanded(
            flex: flex,
            child: child,
          );
        }

        String cycleOrderLabel(AttendanceRecord r) {
          final c = r.cycle;
          final o = r.sessionOrder;
          if (c == null && o == null) return '-';
          if (c == null) return '-/$o';
          if (o == null) return '$c/-';
          return '$c/$o';
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
                cell('회차', flex: 10, align: TextAlign.center),
                cell('날짜', flex: 18, align: TextAlign.center),
                cell('시간', flex: 16, align: TextAlign.center),
                cell('구분', flex: 10, align: TextAlign.center),
                cell('등원', flex: 10, align: TextAlign.center),
                cell('하원', flex: 10, align: TextAlign.center),
                cell('수업명', flex: 28, align: TextAlign.center),
                cell('결과', flex: 12, align: TextAlign.center),
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
          final dateStr = _ymdWithWeekday(dt);
          final timeStr = '${_hm(dt)}~${_hm(r.classEndTime)}';
          final cycleStr = cycleOrderLabel(r);
          final cname = _classNameOf(r, classById);

          final ov = _findOverrideForRecord(ovs, r);
          final bool isWalkIn = r.isPlanned == false;
          final bool isMakeup = ov != null && ov.overrideType == OverrideType.replace;
          final bool isAddOverride = ov != null && ov.overrideType == OverrideType.add;
          final String rowKey = _rowKey(r);
          final bool expanded = isMakeup && _expandedMakeupKey == rowKey;

          final statusWidget = () {
            if (isPlannedRow) {
              final past = _dateOnly(dt).isBefore(today);
              // ✅ 구분: 과거 예정(미출석)은 '기록'으로 통합
              return badge(past ? '기록' : '예정', const Color(0xFF223131));
            }
            if (isMakeup) {
              return MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () {
                    setState(() {
                      _expandedMakeupKey = expanded ? null : rowKey;
                    });
                  },
                  child: badge('보강', const Color(0xFF1976D2)),
                ),
              );
            }
            if (isAddOverride) return badge('추가', const Color(0xFF4CAF50));
            if (isWalkIn) return badge('추가', const Color(0xFF4CAF50));
            return badge('기록', const Color(0xFF223131));
          }();

          final AttendanceResult result = judgeAttendanceResult(
            record: r,
            now: now,
            latenessThresholdMinutes: latenessThresholdMinutes,
            earlyLeaveRatio: 0.6,
          );
          final resultWidget = badge(result.label, result.badgeColor);

          final rowStyle = TextStyle(
            color: dimmed ? Colors.white38 : text,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          );

          final bool showConnectMakeup = !isPlannedRow && isWalkIn && !isMakeup && !isAddOverride;
          // ✅ 추가수업(walk-in)은 '예정 연결'만 보여야 함 → 보강 잡기 버튼은 숨김
          final bool showCatchMakeup = !isWalkIn && (isPlannedRow || result == AttendanceResult.absent);

          DateTime? origStart;
          DateTime? origEnd;
          if (isMakeup) {
            final oid = (r.occurrenceId ?? '').trim();
            if (oid.isNotEmpty) {
              for (final o in AttendanceService.instance.lessonOccurrences) {
                if (o.id == oid) {
                  origStart = o.originalClassDateTime;
                  origEnd = o.originalClassEndTime;
                  origEnd ??= (origStart == null)
                      ? null
                      : origStart!.add(Duration(minutes: (o.durationMinutes ?? 0)));
                  break;
                }
              }
            }
            origStart ??= ov?.originalClassDateTime;
            final durMin = ov?.durationMinutes ?? r.classEndTime.difference(r.classDateTime).inMinutes;
            origEnd ??= (origStart == null)
                ? null
                : origStart!.add(Duration(minutes: durMin <= 0 ? 0 : durMin));
          }

          Widget classCell() {
            final bool hasAction = showConnectMakeup || showCatchMakeup;
            final classNameWidget = Tooltip(
              message: '클릭하여 수업명 수정',
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => editClassNameOf(r),
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        const SizedBox(width: 24),
                        Expanded(
                          child: Text(
                            cname,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: rowStyle,
                            textAlign: TextAlign.left,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );

            if (!hasAction) {
              return Expanded(
                flex: 28,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: classNameWidget,
                ),
              );
            }

            return Expanded(
              flex: 28,
              child: Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: classNameWidget,
                    ),
                  ),
                  if (showConnectMakeup) ...[
                    const SizedBox(width: 10),
                    TextButton(
                      onPressed: () async {
                        final candidates = purePlanned.where((p) => p.id != r.id).toList();
                        await _connectWalkInToPlanned(walkIn: r, candidates: candidates, classById: classById);
                      },
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        minimumSize: const Size(0, 34),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text(
                        '예정 연결',
                        style: TextStyle(color: Color(0xFF33A373), fontWeight: FontWeight.w900),
                      ),
                    ),
                  ],
                  if (showCatchMakeup) ...[
                    const SizedBox(width: 10),
                    TextButton(
                      onPressed: () async {
                        if (!mounted) return;
                        StudentWithInfo? studentWithInfo;
                        for (final s in DataManager.instance.students) {
                          if (s.student.id == widget.studentId) {
                            studentWithInfo = s;
                            break;
                          }
                        }
                        if (studentWithInfo == null) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('학생 정보를 찾을 수 없습니다.')),
                          );
                          return;
                        }

                        final originalAttendanceId = (r.id ?? '').trim().isEmpty ? null : r.id;
                        await showDialog<bool>(
                          context: context,
                          barrierDismissible: true,
                          builder: (context) => MakeupScheduleDialog(
                            studentWithInfo: studentWithInfo!,
                            absentAttendanceId: originalAttendanceId,
                            originalDateTime: r.classDateTime,
                            originalClassName: cname,
                          ),
                        );
                      },
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        minimumSize: const Size(0, 34),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text(
                        '보강 잡기',
                        style: TextStyle(color: Color(0xFF1976D2), fontWeight: FontWeight.w900),
                      ),
                    ),
                  ],
                ],
              ),
            );
          }

          Widget content = Opacity(
            opacity: dimmed ? 0.55 : 1.0,
            child: AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF15171C),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: border, width: 1),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        cell(cycleStr, flex: 10, style: rowStyle, align: TextAlign.center),
                        cell(
                          dateStr,
                          flex: 18,
                          style: rowStyle,
                          onTap: () => editDateOf(r),
                          tooltip: '클릭하여 날짜 수정',
                        ),
                        cell(
                          timeStr,
                          flex: 16,
                          style: rowStyle,
                          onTap: () => editTimeRangeOf(r),
                          tooltip: '클릭하여 시간 수정',
                        ),
                        Expanded(flex: 10, child: Align(alignment: Alignment.center, child: statusWidget)),
                        cell(
                          r.arrivalTime == null ? '-' : _hm(r.arrivalTime!.toLocal()),
                          flex: 10,
                          style: rowStyle,
                          onTap: () => editArrivalOf(r),
                          tooltip: '클릭하여 등원시간 수정',
                        ),
                        cell(
                          r.departureTime == null ? '-' : _hm(r.departureTime!.toLocal()),
                          flex: 10,
                          style: rowStyle,
                          onTap: () => editDepartureOf(r),
                          tooltip: '클릭하여 하원시간 수정',
                        ),
                        classCell(),
                        Expanded(flex: 12, child: Align(alignment: Alignment.center, child: resultWidget)),
                      ],
                    ),
                    if (expanded) ...[
                      const SizedBox(height: 10),
                      Container(height: 1, color: border.withOpacity(0.55)),
                      const SizedBox(height: 10),
                      Opacity(
                        opacity: 0.45,
                        child: Row(
                          children: [
                            cell(cycleStr, flex: 10, style: rowStyle, align: TextAlign.center),
                            cell(origStart == null ? '-' : _ymdWithWeekday(origStart!), flex: 18, style: rowStyle),
                            cell(
                              (origStart == null || origEnd == null)
                                  ? '-'
                                  : '${_hm(origStart!)}~${_hm(origEnd!)}',
                              flex: 16,
                              style: rowStyle,
                            ),
                            Expanded(
                              flex: 10,
                              child: Align(
                                alignment: Alignment.center,
                                child: badge('원본', const Color(0xFF223131)),
                              ),
                            ),
                            cell('-', flex: 10, style: rowStyle),
                            cell('-', flex: 10, style: rowStyle),
                            Expanded(
                              flex: 28,
                              child: Tooltip(
                                message: '클릭하여 수업명 수정',
                                child: Material(
                                  color: Colors.transparent,
                                  child: InkWell(
                                    onTap: () => editClassNameOf(r),
                                    borderRadius: BorderRadius.circular(6),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 4),
                                      child: Row(
                                        children: [
                                          const SizedBox(width: 24),
                                          Expanded(
                                            child: Text(
                                              cname,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: rowStyle,
                                              textAlign: TextAlign.left,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            cell('-', flex: 12, style: rowStyle, align: TextAlign.center),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );

          if (expanded) {
            content = TapRegion(
              onTapOutside: (_) {
                if (!mounted) return;
                setState(() => _expandedMakeupKey = null);
              },
              child: content,
            );
          }

          return content;
        }

        Widget todayDivider() {
          final label = _ymdWithWeekday(today);
          const accent = Color(0xFF33A373);
          return Padding(
            key: _todayDividerKey,
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                const Expanded(child: SizedBox(height: 1, child: ColoredBox(color: accent))),
                const SizedBox(width: 12),
                Text(
                  '오늘 · $label',
                  style: const TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w900),
                ),
                const SizedBox(width: 12),
                const Expanded(child: SizedBox(height: 1, child: ColoredBox(color: accent))),
              ],
            ),
          );
        }

        final items = <Widget>[];

        // 1) 과거(출석 기록 + 오늘 이전 예정)
        for (final r in mergedPast) {
          final dimmed = false; // ✅ 출결기록 비활성(흐림) 효과 제거
          items.add(rowTile(r: r, dimmed: dimmed, isPlannedRow: _isPurePlanned(r)));
          items.add(const SizedBox(height: 8));
        }

        final showTodayDivider = mergedPast.isNotEmpty && plannedFuture.isNotEmpty;

        // 2) 오늘 기준 구분선 (과거/미래 모두 있을 때만)
        if (showTodayDivider) {
          items.add(todayDivider());
        }

        // 3) 미래(오늘 포함 예정)
        for (final r in plannedFuture) {
          final dimmed = false;
          items.add(rowTile(r: r, dimmed: dimmed, isPlannedRow: true));
          items.add(const SizedBox(height: 8));
        }

        // ✅ 진입 시: 오늘 디바이더가 가운데 오도록(가능한 경우) 1회 스크롤 정렬
        void maybeCenterTodayDivider() {
          if (!showTodayDivider) return;
          if (_didCenterTodayDivider || _centeringTodayDividerPending) return;
          _centeringTodayDividerPending = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _centeringTodayDividerPending = false;
            if (!mounted) return;
            final ctx = _todayDividerKey.currentContext;
            if (ctx == null) return;
            Scrollable.ensureVisible(
              ctx,
              alignment: 0.5,
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
            );
            _didCenterTodayDivider = true;
          });
        }
        maybeCenterTodayDivider();

        return Column(
          children: [
            headerRow(),
            const SizedBox(height: 10),
            Expanded(
              child: Scrollbar(
                controller: _scrollController,
                child: ListView(
                  controller: _scrollController,
                  children: items,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _QueryRangeDropdown extends StatelessWidget {
  final DateTime start; // date-only
  final DateTime end; // date-only
  final void Function(DateTime nextStart, DateTime nextEnd) onChanged;

  const _QueryRangeDropdown({
    required this.start,
    required this.end,
    required this.onChanged,
  });

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  static String _pretty(DateTime d) => '${d.year}. ${d.month}. ${d.day}.';

  static DateTime _shiftMonthsClamped(DateTime base, int deltaMonths) {
    int y = base.year;
    int m = base.month + deltaMonths;
    while (m <= 0) {
      m += 12;
      y -= 1;
    }
    while (m > 12) {
      m -= 12;
      y += 1;
    }
    final int lastDay = DateUtils.getDaysInMonth(y, m);
    final int d = base.day > lastDay ? lastDay : base.day;
    return DateTime(y, m, d);
  }

  Future<DateTime?> _pick(
    BuildContext context, {
    required DateTime initial,
    required DateTime first,
    required DateTime last,
  }) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
      locale: const Locale('ko', 'KR'),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: Color(0xFF1B6B63),
              onPrimary: Colors.white,
              surface: Color(0xFF0B1112),
              onSurface: Color(0xFFEAF2F2),
            ),
            dialogBackgroundColor: const Color(0xFF0B1112),
          ),
          child: child!,
        );
      },
    );
    return picked == null ? null : _dateOnly(picked);
  }

  @override
  Widget build(BuildContext context) {
    const border = Color(0xFF223131);
    const bg = Color(0xFF151C21);
    const text = Color(0xFFEAF2F2);
    const sub = Color(0xFF9FB3B3);

    final DateTime s = _dateOnly(start);
    final DateTime e = _dateOnly(end);
    final DateTime today = _dateOnly(DateTime.now());
    final DateTime first = DateTime(today.year - 5, 1, 1);
    final DateTime last = DateTime(today.year + 5, 12, 31);

    Widget dateCell({
      required String value,
      required VoidCallback onTap,
    }) {
      return Expanded(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      value,
                      style: const TextStyle(color: text, fontSize: 16, fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Icon(Icons.calendar_month, color: sub, size: 20),
                ],
              ),
            ),
          ),
        ),
      );
    }

    PopupMenuItem<_QueryRangePreset> item(_QueryRangePreset preset, String label) {
      return PopupMenuItem<_QueryRangePreset>(
        value: preset,
        child: Text(
          label,
          style: const TextStyle(color: text, fontSize: 14, fontWeight: FontWeight.w700),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border, width: 1),
      ),
      child: Row(
        children: [
          dateCell(
            value: _pretty(s),
            onTap: () async {
              final picked = await _pick(context, initial: s, first: first, last: last);
              if (picked == null) return;
              // start가 end보다 커지면 end를 start로 당겨 일관성 유지
              final nextStart = picked;
              final nextEnd = nextStart.isAfter(e) ? nextStart : e;
              onChanged(nextStart, nextEnd);
            },
          ),
          Container(width: 1, height: 42, color: border.withOpacity(0.7)),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 10),
            child: Text('~', style: TextStyle(color: sub, fontSize: 18, fontWeight: FontWeight.w800)),
          ),
          Container(width: 1, height: 42, color: border.withOpacity(0.7)),
          dateCell(
            value: _pretty(e),
            onTap: () async {
              final picked = await _pick(context, initial: e, first: first, last: last);
              if (picked == null) return;
              // end가 start보다 작아지면 start를 end로 당겨 일관성 유지
              final nextEnd = picked;
              final nextStart = nextEnd.isBefore(s) ? nextEnd : s;
              onChanged(nextStart, nextEnd);
            },
          ),
          Container(width: 1, height: 42, color: border.withOpacity(0.7)),
          SizedBox(
            width: 160,
            child: PopupMenuButton<_QueryRangePreset>(
              tooltip: '기간 프리셋',
              color: const Color(0xFF0B1112),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: border.withOpacity(0.9), width: 1),
              ),
              itemBuilder: (context) => [
                item(_QueryRangePreset.last7Days, '최근 7일'),
                item(_QueryRangePreset.last30Days, '최근 30일'),
                item(_QueryRangePreset.last3Months, '최근 3개월'),
                item(_QueryRangePreset.thisYear, '올해'),
                item(_QueryRangePreset.all, '전체'),
              ],
              onSelected: (preset) {
                DateTime nextStart = s;
                DateTime nextEnd = e;
                switch (preset) {
                  case _QueryRangePreset.last7Days:
                    nextEnd = today;
                    nextStart = today.subtract(const Duration(days: 6));
                    break;
                  case _QueryRangePreset.last30Days:
                    nextEnd = today;
                    nextStart = today.subtract(const Duration(days: 29));
                    break;
                  case _QueryRangePreset.last3Months:
                    nextEnd = today;
                    nextStart = _shiftMonthsClamped(today, -3);
                    break;
                  case _QueryRangePreset.thisYear:
                    nextEnd = today;
                    nextStart = DateTime(today.year, 1, 1);
                    break;
                  case _QueryRangePreset.all:
                    nextEnd = today;
                    // ✅ "전체"는 date picker 기본 범위(최근 5년) 내에서 최대한 넓게
                    nextStart = DateTime(today.year - 5, today.month, today.day);
                    break;
                }
                // 안전 보정
                if (nextStart.isAfter(nextEnd)) {
                  final t = nextStart;
                  nextStart = nextEnd;
                  nextEnd = t;
                }
                // picker 범위 밖으로 튀어나가는 경우 방지
                if (nextStart.isBefore(first)) nextStart = first;
                if (nextEnd.isAfter(last)) nextEnd = last;
                onChanged(_dateOnly(nextStart), _dateOnly(nextEnd));
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: const [
                    Expanded(
                      child: Text(
                        '프리셋',
                        style: TextStyle(color: text, fontSize: 15, fontWeight: FontWeight.w700),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(Icons.arrow_drop_down, color: sub, size: 22),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _QueryRangePreset {
  last7Days,
  last30Days,
  last3Months,
  thisYear,
  all,
}

class _ScheduleEntry {
  final String key;
  final String? setId;
  final List<String> blockIds; // 이 row가 대표하는 실제 student_time_blocks id 목록(하드삭제/수정 대상)
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
    required this.blockIds,
    required this.startDate,
    required this.endDate,
    required this.dayIndex,
    required this.startMinute,
    required this.endMinute,
    required this.sessionTypeId,
    required this.modifiedAt,
  });
}


