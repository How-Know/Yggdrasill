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
      backgroundColor: const Color(0xFF1F1F1F),
      title: Text('수업 일정 - ${widget.studentWithInfo.student.name}', style: const TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 560,
        height: dialogHeight,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView.separated(
                itemCount: _sessions.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, i) {
                  final s = _sessions[i];
                  final date = s.dateTime;
                  final label = '${date.year}.${date.month.toString().padLeft(2, '0')}.${date.day.toString().padLeft(2, '0')} (${_dayKo(date.weekday)}) ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
                  return ListTile(
                    tileColor: const Color(0xFF2A2A2A),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    title: Text(label, style: const TextStyle(color: Colors.white)),
                    subtitle: Text(s.className, style: const TextStyle(color: Colors.white70)),
                    onTap: () => Navigator.of(context).pop<DateTime>(s.dateTime),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop<DateTime?>(null),
          child: const Text('닫기', style: TextStyle(color: Colors.white70)),
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
      backgroundColor: const Color(0xFF1F1F1F),
      title: const Text('빠른 보강 등록', style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 640,
        height: 520,
        child: Column(
          children: [
            TextField(
              controller: _searchController,
              onChanged: _onQueryChanged,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: '학생 검색',
                labelStyle: const TextStyle(color: Colors.white70),
                prefixIcon: const Icon(Icons.search, color: Colors.white70),
                enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white.withOpacity(0.3))),
                focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2A2A),
                  borderRadius: BorderRadius.circular(8),
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
                      separatorBuilder: (_, __) => const Divider(color: Colors.white12, height: 1),
                      itemBuilder: (context, i) {
                        final s = items[i];
                        final sub = subtitles[i];
                        final absentId = isSearching ? null : _recentAbsentByStudentId[s.student.id]?.id;
                        return ListTile(
                          title: Text(s.student.name, style: const TextStyle(color: Colors.white)),
                          subtitle: Text(sub, style: const TextStyle(color: Colors.white70)),
                          onTap: () => _openSchedule(s, absentRecordId: absentId),
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
          child: const Text('닫기', style: TextStyle(color: Colors.white70)),
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
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF1F1F1F),
          title: const Text('보강 등록 확인', style: TextStyle(color: Colors.white)),
          content: Text(
            '$studentName 학생의 "$classLabel"을\n$src → $dst 로 보강 예약했습니다.',
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('확인', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
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
      backgroundColor: const Color(0xFF1F1F1F),
      title: Text('${widget.studentWithInfo.student.name} 보강 시간 선택', style: const TextStyle(color: Colors.white)),
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
                            registrationModeType: null,
                            isRegistrationMode: false,
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
          child: const Text('닫기', style: TextStyle(color: Colors.white70)),
        ),
      ],
    );
  }
}

// 학생 수업 선택 단계는 제거: 보강은 수업종류 지정 없이 진행




