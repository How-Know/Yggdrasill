import 'package:flutter/material.dart';
import '../models/student.dart';
import '../models/education_level.dart';
import '../models/attendance_record.dart';
import '../models/student_time_block.dart';
import '../models/class_info.dart';
import '../screens/timetable/components/attendance_check_view.dart' show ClassSession, AttendanceCheckView;
import '../screens/timetable/components/timetable_header.dart';
import '../services/data_manager.dart';
import '../models/session_override.dart';
import '../models/operating_hours.dart';
import '../screens/timetable/views/classes_view.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';

const Color _mkBg = Color(0xFF0B1112);
const Color _mkPanelBg = Color(0xFF10171A);
const Color _mkFieldBg = Color(0xFF15171C);
const Color _mkBorder = Color(0xFF223131);
const Color _mkText = Color(0xFFEAF2F2);
const Color _mkTextSub = Color(0xFF9FB3B3);
const Color _mkAccent = Color(0xFF33A373);

class MakeupQuickDialog extends StatefulWidget {
  const MakeupQuickDialog({super.key});

  @override
  State<MakeupQuickDialog> createState() => _MakeupQuickDialogState();
}
class StudentScheduleListDialog extends StatefulWidget {
  final StudentWithInfo studentWithInfo;
  const StudentScheduleListDialog({super.key, required this.studentWithInfo});

  @override
  State<StudentScheduleListDialog> createState() => _StudentScheduleListDialogState();
}

class _StudentScheduleListDialogState extends State<StudentScheduleListDialog> {
  bool _loading = true;
  List<ClassSession> _sessions = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await DataManager.instance.loadStudentTimeBlocks();
      await DataManager.instance.loadSessionOverrides();
      await DataManager.instance.loadAttendanceRecords();
    } catch (_) {}
    _sessions = _computeUpcomingSessions(widget.studentWithInfo.student.id);
    setState(() => _loading = false);
  }

  List<ClassSession> _computeUpcomingSessions(String studentId) {
    // 간단 버전: 학생의 시간블록을 기반으로 이번 주부터 8주치 기준세션 생성
    final List<ClassSession> list = [];
    final blocks = DataManager.instance.studentTimeBlocks.where((b) => b.studentId == studentId).toList();
    final lessonDuration = DataManager.instance.academySettings.lessonDuration;
    final now = DateTime.now();
    final startWeek = DateTime(now.year, now.month, now.day).subtract(Duration(days: now.weekday - 1));
    for (int w = 0; w < 8; w++) {
      final weekStart = startWeek.add(Duration(days: 7 * w));
      for (final b in blocks) {
        final date = weekStart.add(Duration(days: b.dayIndex));
        final dt = DateTime(date.year, date.month, date.day, b.startHour, b.startMinute);
        list.add(ClassSession(
          dateTime: dt,
          className: '수업',
          dayOfWeek: _dayKoIndex(b.dayIndex),
          duration: lessonDuration,
        ));
      }
    }
    // TODO: sessionOverrides를 반영(휴강/보강)하여 실제 예정만 남기도록 개선 가능
    list.sort((a, b) => a.dateTime.compareTo(b.dateTime));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final itemHeight = 72.0;
    final visible = (_sessions.length < 8 ? _sessions.length : 8);
    final dialogHeight = (visible * itemHeight) + 40;
    return AlertDialog(
      backgroundColor: _mkBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: _mkBorder),
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      title: Row(
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
              onPressed: () => Navigator.of(context).pop<DateTime?>(null),
            ),
          ),
          Expanded(
            child: Text(
              '수업 일정 · ${widget.studentWithInfo.student.name}',
              style: const TextStyle(color: _mkText, fontSize: 20, fontWeight: FontWeight.w800),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 560,
        height: dialogHeight,
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: _mkAccent))
            : ListView.separated(
                itemCount: _sessions.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, i) {
                  final s = _sessions[i];
                  final date = s.dateTime;
                  final label = '${date.year}.${date.month.toString().padLeft(2, '0')}.${date.day.toString().padLeft(2, '0')} (${_dayKo(date.weekday)}) ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
                  return InkWell(
                    onTap: () => Navigator.of(context).pop<DateTime>(s.dateTime),
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: _mkFieldBg,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: _mkBorder.withOpacity(0.9)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.event, color: _mkTextSub, size: 18),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  label,
                                  style: const TextStyle(color: _mkText, fontSize: 14, fontWeight: FontWeight.w700),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  s.className,
                                  style: const TextStyle(color: _mkTextSub, fontSize: 12, fontWeight: FontWeight.w600),
                                  overflow: TextOverflow.ellipsis,
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
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop<DateTime?>(null),
          style: TextButton.styleFrom(
            foregroundColor: _mkTextSub,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          ),
          child: const Text('닫기'),
        ),
      ],
    );
  }

  String _dayKo(int weekday) {
    const days = {1: '월', 2: '화', 3: '수', 4: '목', 5: '금', 6: '토', 7: '일'};
    return days[weekday] ?? '?';
  }

  String _dayKoIndex(int dayIndex) {
    const days = {0: '월', 1: '화', 2: '수', 3: '목', 4: '금', 5: '토', 6: '일'};
    return days[dayIndex] ?? '?';
  }
}

class _MakeupQuickDialogState extends State<MakeupQuickDialog> {
  final TextEditingController _searchController = ImeAwareTextEditingController();
  List<StudentWithInfo> _allStudents = [];
  List<StudentWithInfo> _filtered = [];
  List<String> _recommendedStudentIds = [];
  final Map<String, AttendanceRecord> _recentAbsentByStudentId = {};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  DateTime _today() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  bool _isActive(StudentTimeBlock b, DateTime refDate) {
    final s = DateTime(b.startDate.year, b.startDate.month, b.startDate.day);
    final e = b.endDate != null ? DateTime(b.endDate!.year, b.endDate!.month, b.endDate!.day) : null;
    return !s.isAfter(refDate) && (e == null || !e.isBefore(refDate));
  }

  Color? _resolveStudentClassColor(String studentId) {
    // 활성 시간블록 → sessionTypeId → ClassInfo.color
    final ref = _today();
    final blocks = DataManager.instance.studentTimeBlocks
        .where((b) => b.studentId == studentId && _isActive(b, ref))
        .toList();
    if (blocks.isEmpty) return null;

    // 정렬: weeklyOrder 우선(있으면), 그 다음 요일/시간
    blocks.sort((a, b) {
      final ao = a.weeklyOrder ?? 1 << 30;
      final bo = b.weeklyOrder ?? 1 << 30;
      if (ao != bo) return ao.compareTo(bo);
      if (a.dayIndex != b.dayIndex) return a.dayIndex.compareTo(b.dayIndex);
      final at = a.startHour * 60 + a.startMinute;
      final bt = b.startHour * 60 + b.startMinute;
      return at.compareTo(bt);
    });

    String? sessionTypeId;
    for (final b in blocks) {
      final id = b.sessionTypeId;
      if (id != null && id.isNotEmpty) {
        sessionTypeId = id;
        break;
      }
    }
    if (sessionTypeId == null) return null;

    for (final c in DataManager.instance.classes) {
      if (c.id == sessionTypeId) return c.color;
    }
    return null;
  }

  void _refresh() {
    _allStudents = DataManager.instance.students;
    _filtered = _allStudents;
    _recommendedStudentIds = _computeRecommendedStudents();
    setState(() {});
  }

  List<String> _computeRecommendedStudents() {
    final now = DateTime.now();
    final weekAgo = now.subtract(const Duration(days: 7));
    final absent = DataManager.instance.attendanceRecords.where((r) {
      return !r.isPresent && r.classDateTime.isAfter(weekAgo) && r.classDateTime.isBefore(now.add(const Duration(days: 1)));
    }).toList();
    // 최근 무단결석 레코드 매핑(학생당 가장 최근)
    _recentAbsentByStudentId.clear();
    absent.sort((a, b) => b.classDateTime.compareTo(a.classDateTime));
    for (final r in absent) {
      _recentAbsentByStudentId.putIfAbsent(r.studentId, () => r);
    }
    final ids = _recentAbsentByStudentId.keys.toList();
    return ids;
  }

  void _onQueryChanged(String q) {
    final query = q.trim().toLowerCase();
    setState(() {
      if (query.isEmpty) {
        _filtered = _allStudents;
      } else {
        _filtered = _allStudents.where((s) {
          final name = s.student.name.toLowerCase();
          final school = s.student.school.toLowerCase();
          return name.contains(query) || school.contains(query);
        }).toList();
      }
    });
  }

  Future<void> _openSchedule(StudentWithInfo s, {String? absentRecordId}) async {
    // PERF: 시작 로그
    // ignore: avoid_print
    print('[PERF][QuickMakeup] openSchedule start: ${DateTime.now().toIso8601String()}');
    // 기존 수강탭의 수업일정 리스트 다이얼로그 UX 재사용: AttendanceCheckView의 리스트 다이얼로그 사용
    DateTime? pickedOriginal;
    String? pickedClassName;
    bool? listResult = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (context) => Opacity(
        opacity: 0.0,
        child: AttendanceCheckView(
          selectedStudent: s,
          autoOpenListOnStart: true,
          onReplaceSelected: (session) async {
            pickedOriginal = session.dateTime;
            pickedClassName = session.className;
            // ignore: avoid_print
            print('[PERF][QuickMakeup] picked original at list: ${pickedOriginal!.toIso8601String()}');
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop(true); // 닫고 다음 단계로 이동
            }
          },
          listOnly: true,
        ),
      ),
    );
    // 일부 플랫폼에서 위의 pop 콜백이 먼저 실행되어 listResult가 null일 수 있으므로 보호
    if (pickedOriginal == null) return;
    // ignore: avoid_print
    print('[PERF][QuickMakeup] list closed: ${DateTime.now().toIso8601String()}');
    if (pickedOriginal == null) return;
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (context) => MakeupScheduleDialog(
        studentWithInfo: s,
        absentAttendanceId: absentRecordId,
        originalDateTime: pickedOriginal,
        originalClassName: pickedClassName,
      ),
    );
    // ignore: avoid_print
    print('[PERF][QuickMakeup] schedule dialog closed: ${DateTime.now().toIso8601String()}, saved=$saved');
    if (saved == true) {
      // 보강 저장 후 빠른 보강(현재 다이얼로그)도 닫기
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _mkBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: _mkBorder),
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      title: Row(
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
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          const Expanded(
            child: Text(
              '빠른 보강 등록',
              style: TextStyle(color: _mkText, fontSize: 20, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 720,
        height: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Divider(color: _mkBorder, height: 1),
            const SizedBox(height: 16),
            TextField(
              controller: _searchController,
              onChanged: _onQueryChanged,
              style: const TextStyle(color: _mkText),
              decoration: InputDecoration(
                labelText: '학생 검색',
                labelStyle: const TextStyle(color: _mkTextSub, fontWeight: FontWeight.w700),
                hintText: '이름/학교로 검색',
                hintStyle: const TextStyle(color: Colors.white38),
                prefixIcon: const Icon(Icons.search, color: _mkTextSub),
                filled: true,
                fillColor: _mkFieldBg,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: _mkBorder.withOpacity(0.9)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: _mkAccent, width: 2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: _mkPanelBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _mkBorder),
                ),
                child: ValueListenableBuilder<List<AttendanceRecord>>(
                  valueListenable: DataManager.instance.attendanceRecordsNotifier,
                  builder: (context, _, __) {
                    final isSearching = _searchController.text.trim().isNotEmpty;
                    final items = <StudentWithInfo>[];
                    final subtitles = <String>[];
                    if (isSearching) {
                      for (final s in _filtered) {
                        items.add(s);
                        subtitles.add('${s.student.school} · ${s.student.grade}학년');
                      }
                    } else {
                      // 추천 리스트 (최근 무단결석 순)
                      for (final id in _recommendedStudentIds) {
                        final s = _allStudents.firstWhere(
                          (x) => x.student.id == id,
                          orElse: () => StudentWithInfo(
                            student: Student(id: id, name: '학생', school: '', grade: 0, educationLevel: EducationLevel.elementary),
                            basicInfo: StudentBasicInfo(studentId: id),
                          ),
                        );
                        items.add(s);
                        final absent = _recentAbsentByStudentId[id];
                        final sub = absent == null
                            ? s.student.school
                            : '${s.student.school} · 결석: ${absent.classDateTime.month}/${absent.classDateTime.day} ${absent.classDateTime.hour.toString().padLeft(2, '0')}:${absent.classDateTime.minute.toString().padLeft(2, '0')}';
                        subtitles.add(sub);
                      }
                    }
                    return ListView.separated(
                      itemCount: items.length,
                      separatorBuilder: (_, __) => const Divider(color: Color(0x22FFFFFF), height: 1),
                      itemBuilder: (context, i) {
                        final s = items[i];
                        final sub = subtitles[i];
                        final absentId = isSearching ? null : _recentAbsentByStudentId[s.student.id]?.id;
                        final Color? classColor = _resolveStudentClassColor(s.student.id);
                        return InkWell(
                          onTap: () => _openSchedule(s, absentRecordId: absentId),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            child: Row(
                              children: [
                                classColor == null
                                    ? const SizedBox(width: 10, height: 38)
                                    : Container(
                                        width: 10,
                                        height: 38,
                                        decoration: BoxDecoration(
                                          color: classColor,
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                      ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        s.student.name,
                                        style: const TextStyle(color: _mkText, fontSize: 15, fontWeight: FontWeight.w700),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        sub,
                                        style: const TextStyle(color: _mkTextSub, fontSize: 12, fontWeight: FontWeight.w600),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const Icon(Icons.chevron_right, color: _mkTextSub),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(
            foregroundColor: _mkTextSub,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          ),
          child: const Text('닫기'),
        )
      ],
    );
  }
}

class MakeupScheduleDialog extends StatefulWidget {
  final StudentWithInfo studentWithInfo;
  final String? absentAttendanceId;
  final DateTime? originalDateTime; // 있으면 replace(이번 회차만 변경)
  final String? originalClassName;
  const MakeupScheduleDialog({super.key, required this.studentWithInfo, this.absentAttendanceId, this.originalDateTime, this.originalClassName});

  @override
  State<MakeupScheduleDialog> createState() => _MakeupScheduleDialogState();
}

class _MakeupScheduleDialogState extends State<MakeupScheduleDialog> {
  List<OperatingHours> _hours = [];
  late DateTime _weekStart; // 해당 주 월요일
  final ScrollController _scrollController = ScrollController();
  String _two(int n) => n.toString().padLeft(2, '0');

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _weekStart = now.subtract(Duration(days: now.weekday - 1));
    _load();
  }

  Future<void> _load() async {
    final hours = await DataManager.instance.getOperatingHours();
    await DataManager.instance.loadSessionOverrides();
    setState(() {
      _hours = hours;
    });
  }

  Future<void> _addMakeup(int dayIdx, DateTime timeOfDay) async {
    final date = _weekStart.add(Duration(days: dayIdx));
    final dt = DateTime(date.year, date.month, date.day, timeOfDay.hour, timeOfDay.minute);
    final duration = DataManager.instance.academySettings.lessonDuration;
    final bool isReplace = widget.originalDateTime != null;
    final ov = SessionOverride(
      studentId: widget.studentWithInfo.student.id,
      overrideType: isReplace ? OverrideType.replace : OverrideType.add,
      status: OverrideStatus.planned,
      originalClassDateTime: widget.originalDateTime,
      replacementClassDateTime: dt,
      durationMinutes: duration,
      reason: OverrideReason.makeup,
      originalAttendanceId: widget.absentAttendanceId,
    );
    try {
      await DataManager.instance.addSessionOverride(ov);
      if (!mounted) return;
      // 확인 다이얼로그 표시
      final classLabel = widget.originalClassName ?? '수업';
      final studentName = widget.studentWithInfo.student.name;
      final src = widget.originalDateTime != null
          ? '${widget.originalDateTime!.month}/${widget.originalDateTime!.day} ${_two(widget.originalDateTime!.hour)}:${_two(widget.originalDateTime!.minute)}'
          : '선택 전';
      final dst = '${dt.month}/${dt.day} ${_two(dt.hour)}:${_two(dt.minute)}';
      await showDialog(
        context: context,
        builder: (context) {
          String dow(int weekday) {
            const days = {1: '월', 2: '화', 3: '수', 4: '목', 5: '금', 6: '토', 7: '일'};
            return days[weekday] ?? '?';
          }

          String pretty(DateTime d) {
            return '${d.month}/${d.day} (${dow(d.weekday)}) ${_two(d.hour)}:${_two(d.minute)}';
          }

          final bool isReplace = widget.originalDateTime != null;
          final String title = isReplace ? '보강 예약 완료' : '추가 수업 예약 완료';
          final String srcPretty = widget.originalDateTime == null ? '선택 전' : pretty(widget.originalDateTime!);
          final String dstPretty = pretty(dt);

          Widget timeCard({
            required IconData icon,
            required String label,
            required String value,
            required Color iconColor,
          }) {
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: _mkFieldBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _mkBorder.withOpacity(0.9)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: iconColor.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: iconColor.withOpacity(0.25)),
                    ),
                    child: Icon(icon, color: iconColor, size: 18),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label, style: const TextStyle(color: _mkTextSub, fontSize: 12, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 2),
                        Text(
                          value,
                          style: const TextStyle(color: _mkText, fontSize: 15, fontWeight: FontWeight.w900),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }

          return AlertDialog(
            backgroundColor: _mkBg,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: _mkBorder),
            ),
            titlePadding: const EdgeInsets.fromLTRB(24, 22, 24, 10),
            contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
            actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
            title: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: _mkAccent.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _mkAccent.withOpacity(0.28)),
                  ),
                  child: const Icon(Icons.check_rounded, color: _mkAccent, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(color: _mkText, fontSize: 18, fontWeight: FontWeight.w900)),
                      const SizedBox(height: 2),
                      Text(
                        '$studentName · $classLabel',
                        style: const TextStyle(color: _mkTextSub, fontSize: 13, fontWeight: FontWeight.w700),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                timeCard(
                  icon: Icons.event,
                  label: isReplace ? '원본 수업' : '기준 수업',
                  value: isReplace ? srcPretty : src,
                  iconColor: Colors.white70,
                ),
                const SizedBox(height: 10),
                const Center(child: Icon(Icons.south_rounded, color: _mkTextSub)),
                const SizedBox(height: 10),
                timeCard(
                  icon: Icons.event_repeat_rounded,
                  label: '보강 시간',
                  value: dstPretty,
                  iconColor: _mkAccent,
                ),
                const SizedBox(height: 12),
                const Text(
                  '시간표에서 선택한 시간으로 보강이 예약되었습니다.',
                  style: TextStyle(color: Colors.white60, fontSize: 12, fontWeight: FontWeight.w600, height: 1.35),
                ),
              ],
            ),
            actions: [
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _mkAccent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('확인', style: TextStyle(fontWeight: FontWeight.w900)),
                ),
              ),
            ],
          );
        },
      );
      Navigator.of(context).pop(true); // 보강 저장 후 즉시 닫기
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('보강 등록 실패: $e'),
          backgroundColor: const Color(0xFFE53E3E),
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _mkBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: _mkBorder),
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      title: Text(
        '${widget.studentWithInfo.student.name} 보강 시간 선택',
        style: const TextStyle(color: _mkText, fontSize: 20, fontWeight: FontWeight.w800),
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: 1032, // 860 * 1.2
        height: 672, // 560 * 1.2
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 상단: 시간탭과 동일한 월 기준 주차/화살표 헤더 사용
                  TimetableHeader(
                    selectedDate: _weekStart,
                    onDateChanged: (newDate) {
                      final monday = newDate.subtract(Duration(days: newDate.weekday - 1));
                      setState(() {
                        _weekStart = monday;
                      });
                    },
                    selectedDayIndex: null,
                    onDaySelected: (_) {},
                    isRegistrationMode: false,
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: _hours.isEmpty
                        ? const Center(child: CircularProgressIndicator())
                        : ClassesView(
                            scrollController: _scrollController,
                            operatingHours: _hours,
                            breakTimeColor: const Color(0xFF424242),
                            // ✅ 보강 시간 선택: 클릭 + 드래그 모두 허용(수업시간 등록과 동일한 드래그 UX 재사용)
                            registrationModeType: 'makeup',
                            isRegistrationMode: true,
                            selectedDayIndex: null,
                            weekStartDate: _weekStart,
                            selectedStudentWithInfo: null,
                            onTimeSelected: (dayIdx, startTime) async {
                              await _addMakeup(dayIdx, startTime);
                              setState(() {});
                            },
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(
            foregroundColor: _mkTextSub,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          ),
          child: const Text('닫기'),
        ),
      ],
    );
  }
}

// 학생 수업 선택 단계는 제거: 보강은 수업종류 지정 없이 진행




