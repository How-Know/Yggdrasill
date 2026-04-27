import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../models/student.dart';
import '../../../models/education_level.dart';
import '../../../services/data_manager.dart';
import '../../../services/tenant_service.dart';

/// 학생 알림 동의 다이얼로그. 전체 학생 리스트를 학년별로 표시하고,
/// 연락처 여부(본인/부모) + 알림 동의 체크박스를 노출한다.
/// 동의 상태는 student_basic_info.notification_consent에 저장된다.
class StudentNotificationConsentDialog extends StatefulWidget {
  const StudentNotificationConsentDialog({super.key});

  @override
  State<StudentNotificationConsentDialog> createState() =>
      _StudentNotificationConsentDialogState();
}

class _StudentNotificationConsentDialogState
    extends State<StudentNotificationConsentDialog> {
  static const double _cardHeight = 42.0;
  static double get _allStudentsListRowHeight => (_cardHeight * 1.3) + 12;

  final Set<String> _agreedStudentIds = {};
  final List<DateTime> _pauseDates = [];
  String? _expandedGradeKey;
  bool _initialized = false;
  bool _pauseDatesLoading = false;
  String? _pauseDatesError;

  @override
  void initState() {
    super.initState();
    _loadPauseDates();
  }

  DateTime _normalizeDate(DateTime date) =>
      DateTime(date.year, date.month, date.day);

  String _dateKey(DateTime date) {
    final d = _normalizeDate(date);
    final month = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$month-$day';
  }

  DateTime? _parseDateKey(dynamic value) {
    final text = value?.toString();
    if (text == null || text.isEmpty) return null;
    try {
      return _normalizeDate(DateTime.parse(text));
    } catch (_) {
      return null;
    }
  }

  String _dateLabel(DateTime date) {
    const weekdays = ['월', '화', '수', '목', '금', '토', '일'];
    return '${date.month}/${date.day}(${weekdays[date.weekday - 1]})';
  }

  Future<String> _activeAcademyId() async {
    return await TenantService.instance.getActiveAcademyId() ??
        await TenantService.instance.ensureActiveAcademy();
  }

  Future<void> _loadPauseDates() async {
    setState(() {
      _pauseDatesLoading = true;
      _pauseDatesError = null;
    });
    try {
      final academyId = await _activeAcademyId();
      final rows = await Supabase.instance.client
          .from('academy_notification_pause_dates')
          .select('pause_date')
          .eq('academy_id', academyId)
          .order('pause_date');
      final dates = <DateTime>[];
      for (final row in rows as List) {
        final parsed = _parseDateKey(row['pause_date']);
        if (parsed != null) dates.add(parsed);
      }
      if (!mounted) return;
      setState(() {
        _pauseDates
          ..clear()
          ..addAll(dates);
        _pauseDatesLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _pauseDatesLoading = false;
        _pauseDatesError = '중지 날짜를 불러오지 못했습니다.';
      });
    }
  }

  Future<void> _addPauseDate() async {
    final today = _normalizeDate(DateTime.now());
    final selected = await showDatePicker(
      context: context,
      initialDate: today,
      firstDate: today,
      lastDate: DateTime(today.year + 2, 12, 31),
      helpText: '알림톡 발송 중지 날짜 선택',
      cancelText: '취소',
      confirmText: '추가',
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: Color(0xFF1B6B63),
              surface: Color(0xFF0B1112),
            ),
          ),
          child: child!,
        );
      },
    );
    if (selected == null) return;

    final date = _normalizeDate(selected);
    final key = _dateKey(date);
    try {
      final academyId = await _activeAcademyId();
      await Supabase.instance.client
          .from('academy_notification_pause_dates')
          .upsert({
        'academy_id': academyId,
        'pause_date': key,
      }, onConflict: 'academy_id,pause_date');
      await _loadPauseDates();
      _showSnack('${_dateLabel(date)} 알림톡 발송을 중지합니다.');
    } catch (e) {
      _showSnack('중지 날짜 저장에 실패했습니다.');
    }
  }

  Future<void> _deletePauseDate(DateTime date) async {
    try {
      final academyId = await _activeAcademyId();
      await Supabase.instance.client
          .from('academy_notification_pause_dates')
          .delete()
          .eq('academy_id', academyId)
          .eq('pause_date', _dateKey(date));
      await _loadPauseDates();
      _showSnack('${_dateLabel(date)} 중지를 해제했습니다.');
    } catch (e) {
      _showSnack('중지 날짜 삭제에 실패했습니다.');
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Map<String, List<StudentWithInfo>> _groupStudentsByGrade(
    List<StudentWithInfo> students,
  ) {
    final grouped = <String, List<StudentWithInfo>>{};
    for (final s in students) {
      final key =
          '${_educationLevelPrefix(s.student.educationLevel)}${s.student.grade}';
      grouped.putIfAbsent(key, () => <StudentWithInfo>[]).add(s);
    }
    for (final list in grouped.values) {
      list.sort((a, b) => a.student.name.compareTo(b.student.name));
    }
    int levelOrder(String key) {
      if (key.startsWith('초')) return 0;
      if (key.startsWith('중')) return 1;
      if (key.startsWith('고')) return 2;
      return 3;
    }

    int gradeNum(String key) {
      final m = RegExp(r'\d+').firstMatch(key);
      if (m == null) return 0;
      return int.tryParse(m.group(0)!) ?? 0;
    }

    final sortedKeys = grouped.keys.toList()
      ..sort((a, b) {
        final byLevel = levelOrder(a).compareTo(levelOrder(b));
        if (byLevel != 0) return byLevel;
        return gradeNum(a).compareTo(gradeNum(b));
      });
    return {for (final k in sortedKeys) k: grouped[k]!};
  }

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

  static String _educationLevelPrefix(EducationLevel level) {
    switch (level) {
      case EducationLevel.elementary:
        return '초';
      case EducationLevel.middle:
        return '중';
      case EducationLevel.high:
        return '고';
    }
    return '';
  }

  void _initFromStudents(List<StudentWithInfo> students) {
    if (_initialized) return;
    _initialized = true;
    for (final s in students) {
      if (s.basicInfo.notificationConsent) {
        _agreedStudentIds.add(s.student.id);
      }
    }
  }

  Future<void> _toggleConsent(StudentWithInfo info, bool value) async {
    setState(() {
      if (value) {
        _agreedStudentIds.add(info.student.id);
      } else {
        _agreedStudentIds.remove(info.student.id);
      }
    });
    final updated = info.basicInfo.copyWith(notificationConsent: value);
    await DataManager.instance.updateStudentBasicInfo(info.student.id, updated);
  }

  Future<void> _toggleGradeAll(
      List<StudentWithInfo> students, bool value) async {
    setState(() {
      for (final s in students) {
        if (value) {
          _agreedStudentIds.add(s.student.id);
        } else {
          _agreedStudentIds.remove(s.student.id);
        }
      }
    });
    for (final s in students) {
      final updated = s.basicInfo.copyWith(notificationConsent: value);
      await DataManager.instance.updateStudentBasicInfo(s.student.id, updated);
    }
  }

  void _toggleGrade(String key) {
    setState(() {
      if (_expandedGradeKey == key) {
        _expandedGradeKey = null;
      } else {
        _expandedGradeKey = key;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final maxListHeight = MediaQuery.of(context).size.height * 0.8;
    return Theme(
      data: Theme.of(context).copyWith(
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
      ),
      child: Dialog(
        backgroundColor: const Color(0xFF0B1112),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                child: Row(
                  children: [
                    const Icon(Symbols.notifications,
                        color: Colors.white70, size: 28),
                    const SizedBox(width: 12),
                    const Text(
                      '알림 동의',
                      style: TextStyle(
                        color: Color(0xFFEAF2F2),
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Color(0xFF223131)),
              _buildPauseDateSection(),
              const Divider(height: 1, color: Color(0xFF223131)),
              ValueListenableBuilder<List<StudentWithInfo>>(
                valueListenable: DataManager.instance.studentsNotifier,
                builder: (context, students, _) {
                  _initFromStudents(students);
                  final grouped = _groupStudentsByGrade(students);
                  if (grouped.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(
                        child: Text(
                          '등록된 학생이 없습니다.',
                          style: TextStyle(
                            color: Color(0xFF9FB3B3),
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    );
                  }
                  final scale = 1.0;
                  final entries = grouped.entries.toList();
                  return ConstrainedBox(
                    constraints:
                        BoxConstraints(maxHeight: maxListHeight * 0.72),
                    child: SingleChildScrollView(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final entry in entries)
                              _buildGradeSection(
                                entry.key,
                                entry.value,
                                scale: scale,
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
              const Divider(height: 1, color: Color(0xFF223131)),
              Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white70,
                      overlayColor: Colors.transparent,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text('닫기'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPauseDateSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.event_busy, color: Colors.white70, size: 22),
              const SizedBox(width: 8),
              const Text(
                '알림톡 발송 중지 날짜',
                style: TextStyle(
                  color: Color(0xFFEAF2F2),
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _pauseDatesLoading ? null : _addPauseDate,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('날짜 추가'),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF8EDBD0),
                  overlayColor: Colors.transparent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            '선택한 날짜에는 등하원/지각/보강 알림톡을 보내지 않고, 지난 날짜 알림은 다음날 발송하지 않습니다.',
            style: TextStyle(
              color: Color(0xFF9FB3B3),
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 10),
          if (_pauseDatesLoading)
            const SizedBox(
              height: 28,
              child: Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (_pauseDatesError != null)
            Row(
              children: [
                Expanded(
                  child: Text(
                    _pauseDatesError!,
                    style: const TextStyle(
                      color: Color(0xFFFFA6A6),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _loadPauseDates,
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF8EDBD0),
                    overlayColor: Colors.transparent,
                  ),
                  child: const Text('다시 시도'),
                ),
              ],
            )
          else if (_pauseDates.isEmpty)
            const Text(
              '등록된 중지 날짜가 없습니다.',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final date in _pauseDates)
                  InputChip(
                    label: Text(_dateLabel(date)),
                    onDeleted: () => _deletePauseDate(date),
                    deleteIcon: const Icon(Icons.close, size: 16),
                    backgroundColor: const Color(0xFF132323),
                    side: const BorderSide(color: Color(0xFF2C4A4A)),
                    labelStyle: const TextStyle(
                      color: Color(0xFFEAF2F2),
                      fontWeight: FontWeight.w700,
                    ),
                    deleteIconColor: Colors.white60,
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildGradeSection(
    String gradeKey,
    List<StudentWithInfo> students, {
    required double scale,
  }) {
    final isExpanded = _expandedGradeKey == gradeKey;
    final String levelName = students.isEmpty
        ? gradeKey
        : _educationLevelToKorean(students.first.student.educationLevel);
    final int grade = students.isEmpty ? 0 : students.first.student.grade;
    final String gradeLabel = grade > 0 ? '$levelName $grade학년' : levelName;
    final allAgreed = students.isNotEmpty &&
        students.every((s) => _agreedStudentIds.contains(s.student.id));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        children: [
          InkWell(
            onTap: () => _toggleGrade(gradeKey),
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
            child: SizedBox(
              height: _allStudentsListRowHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    Text(
                      gradeLabel,
                      style: const TextStyle(
                        color: Color(0xFFEAF2F2),
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 32,
                      height: 32,
                      child: Checkbox(
                        value: allAgreed,
                        tristate: true,
                        onChanged: (_) {
                          _toggleGradeAll(students, !allAgreed);
                        },
                        activeColor: const Color(0xFF1B6B63),
                        fillColor: WidgetStateProperty.resolveWith((states) {
                          if (states.contains(WidgetState.selected)) {
                            return const Color(0xFF1B6B63);
                          }
                          return Colors.white24;
                        }),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${students.length}명',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 14 * scale,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      isExpanded ? Icons.expand_less : Icons.expand_more,
                      color: Colors.white70,
                      size: 20,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (isExpanded) ...[
            const Divider(
              height: 1,
              thickness: 1,
              color: Color(0xFF223131),
            ),
            const SizedBox(height: 6),
            for (final info in students) _buildStudentRow(info),
            const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }

  Widget _buildStudentRow(StudentWithInfo info) {
    final student = info.student;
    final schoolText =
        student.school.trim().isEmpty ? '학교 정보 없음' : student.school.trim();
    final initial = student.name.characters.take(1).toString();
    final hasSelf = (student.phoneNumber ?? '').trim().isNotEmpty ||
        (info.basicInfo.phoneNumber ?? '').trim().isNotEmpty;
    final hasParent = (student.parentPhoneNumber ?? '').trim().isNotEmpty ||
        (info.basicInfo.parentPhoneNumber ?? '').trim().isNotEmpty;
    final agreed = _agreedStudentIds.contains(student.id);

    return SizedBox(
      height: _allStudentsListRowHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            CircleAvatar(
              radius: 15,
              backgroundColor:
                  student.groupInfo?.color ?? const Color(0xFF2C3A3A),
              child: Text(
                initial,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: student.name,
                      style: const TextStyle(
                        color: Color(0xFFEAF2F2),
                        fontSize: 19,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    TextSpan(
                      text: '  $schoolText',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '연락처 본인 : ${hasSelf ? 'O' : 'X'}, 부모님 : ${hasParent ? 'O' : 'X'}',
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 40,
              height: 40,
              child: Checkbox(
                value: agreed,
                onChanged: (value) {
                  _toggleConsent(info, value ?? false);
                },
                activeColor: const Color(0xFF1B6B63),
                fillColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.selected)) {
                    return const Color(0xFF1B6B63);
                  }
                  return Colors.white24;
                }),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
