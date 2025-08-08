import 'package:flutter/material.dart';
import '../../../services/data_manager.dart';
import '../../../models/session_override.dart';

class MakeupView extends StatefulWidget {
  const MakeupView({super.key});

  @override
  State<MakeupView> createState() => _MakeupViewState();
}

class _MakeupViewState extends State<MakeupView> {
  int _segmentIndex = 0; // 0: 예정, 1: 완료, 2: 취소

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 24, left: 24, right: 24),
      decoration: BoxDecoration(
        color: const Color(0xFF18181A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF18181A), width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Text(
                  '보강/예외 관리',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                Expanded(
                  child: Center(
                    child: SizedBox(
                      width: 320,
                      child: SegmentedButton<int>(
                        segments: const [
                          ButtonSegment(value: 0, label: Text('예정')),
                          ButtonSegment(value: 1, label: Text('완료')),
                          ButtonSegment(value: 2, label: Text('취소')),
                        ],
                        selected: {_segmentIndex},
                        onSelectionChanged: (selection) => setState(() => _segmentIndex = selection.first),
                        style: ButtonStyle(
                          backgroundColor: MaterialStateProperty.all(Colors.transparent),
                          foregroundColor: MaterialStateProperty.resolveWith<Color>((states) {
                            if (states.contains(MaterialState.selected)) return Colors.white;
                            return Colors.white70;
                          }),
                          textStyle: MaterialStateProperty.all(const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                        ),
                      ),
                    ),
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: _onAddMakeupPressed,
                  icon: const Icon(Icons.add, size: 26),
                  label: const Text('보강 추가', style: TextStyle(fontSize: 17)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1976D2),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                    minimumSize: const Size(0, 54),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ValueListenableBuilder<List<SessionOverride>>(
                valueListenable: DataManager.instance.sessionOverridesNotifier,
                builder: (context, overrides, _) {
                  final filtered = overrides.where((o) {
                    switch (_segmentIndex) {
                      case 0:
                        return o.status == OverrideStatus.planned;
                      case 1:
                        return o.status == OverrideStatus.completed;
                      case 2:
                        return o.status == OverrideStatus.canceled;
                      default:
                        return true;
                    }
                  }).toList()
                    ..sort((a, b) {
                      // replacement 우선 정렬, 없으면 original 기준
                      final aTime = a.replacementClassDateTime ?? a.originalClassDateTime ?? DateTime.fromMillisecondsSinceEpoch(0);
                      final bTime = b.replacementClassDateTime ?? b.originalClassDateTime ?? DateTime.fromMillisecondsSinceEpoch(0);
                      return aTime.compareTo(bTime);
                    });

                  if (filtered.isEmpty) {
                    return const Center(
                      child: Text('항목이 없습니다', style: TextStyle(color: Colors.white54, fontSize: 16)),
                    );
                  }

                  return ListView.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const Divider(color: Colors.white12, height: 1),
                    itemBuilder: (context, idx) {
                      final item = filtered[idx];
                      return _OverrideTile(item: item);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OverrideTile extends StatelessWidget {
  final SessionOverride item;
  const _OverrideTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final typeLabel = _typeLabel(item.overrideType);
    final statusColor = _statusColor(item.status);
    final original = item.originalClassDateTime;
    final repl = item.replacementClassDateTime;

    return ListTile(
      tileColor: const Color(0xFF2A2A2A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      title: Row(
        children: [
          _Badge(text: typeLabel, color: _typeColor(item.overrideType)),
          const SizedBox(width: 8),
          if (item.status == OverrideStatus.planned)
            _Badge(text: '예정', color: statusColor)
          else if (item.status == OverrideStatus.completed)
            _Badge(text: '완료', color: statusColor)
          else
            _Badge(text: '취소', color: statusColor),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (original != null)
              Text('원본: ${_fmt(original)}', style: const TextStyle(color: Colors.white70)),
            if (repl != null)
              Text('대체: ${_fmt(repl)}', style: const TextStyle(color: Colors.white70)),
            if (item.durationMinutes != null)
              Text('기간: ${item.durationMinutes}분', style: const TextStyle(color: Colors.white70)),
          ],
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (item.status == OverrideStatus.planned)
            TextButton(
              onPressed: () async {
                final updated = await showDialog<SessionOverride>(
                  context: context,
                  builder: (_) => _MakeupEditDialog(item: item),
                );
                if (updated != null) {
                  await DataManager.instance.updateSessionOverride(updated);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('보강이 수정되었습니다.'),
                      backgroundColor: Color(0xFF1976D2),
                      duration: Duration(milliseconds: 1400),
                    ));
                  }
                }
              },
              child: const Text('편집'),
            ),
          if (item.status == OverrideStatus.planned)
            TextButton(
              onPressed: () async {
                await DataManager.instance.cancelSessionOverride(item.id);
              },
              child: const Text('취소', style: TextStyle(color: Color(0xFFE53E3E))),
            ),
        ],
      ),
    );
  }

  String _fmt(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} $h:$m';
  }

  String _typeLabel(OverrideType t) {
    switch (t) {
      case OverrideType.skip:
        return '건너뛰기';
      case OverrideType.replace:
        return '대체';
      case OverrideType.add:
        return '추가';
    }
  }

  Color _typeColor(OverrideType t) {
    switch (t) {
      case OverrideType.skip:
        return const Color(0xFFFF9800);
      case OverrideType.replace:
        return const Color(0xFF1976D2);
      case OverrideType.add:
        return const Color(0xFF4CAF50);
    }
  }

  Color _statusColor(OverrideStatus s) {
    switch (s) {
      case OverrideStatus.planned:
        return const Color(0xFF1976D2);
      case OverrideStatus.completed:
        return const Color(0xFF4CAF50);
      case OverrideStatus.canceled:
        return const Color(0xFFE53E3E);
    }
  }
}

extension on _MakeupViewState {
  Future<void> _onAddMakeupPressed() async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => const MakeupAddDialog(),
    );
    if (mounted && saved == true) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('보강이 추가되었습니다.'),
        backgroundColor: Color(0xFF1976D2),
        duration: Duration(milliseconds: 1500),
      ));
    }
  }
}

class MakeupAddDialog extends StatefulWidget {
  const MakeupAddDialog({super.key});

  @override
  State<MakeupAddDialog> createState() => _MakeupAddDialogState();
}

class _MakeupAddDialogState extends State<MakeupAddDialog> {
  String? _studentId;
  String? _studentName;
  DateTime? _selectedDate;
  TimeOfDay? _selectedTime;
  int _duration = 50;

  @override
  void initState() {
    super.initState();
    _duration = DataManager.instance.academySettings.lessonDuration;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      title: const Text('보강 추가', style: TextStyle(color: Colors.white, fontSize: 18)),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 24),
            ListTile(
              leading: const Icon(Icons.person_add_alt_1, color: Colors.white70),
              title: Text(_studentName ?? '학생 선택', style: const TextStyle(color: Colors.white)),
              onTap: _pickStudent,
              tileColor: const Color(0xFF2A2A2A),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(Icons.calendar_today, color: Colors.white70),
              title: Text(_selectedDate == null
                  ? '날짜 선택'
                  : '${_selectedDate!.year}-${_two(_selectedDate!.month)}-${_two(_selectedDate!.day)}',
                  style: const TextStyle(color: Colors.white)),
              onTap: _pickDate,
              tileColor: const Color(0xFF2A2A2A),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(Icons.access_time, color: Colors.white70),
              title: Text(_selectedTime == null
                  ? '시간 선택'
                  : '${_two(_selectedTime!.hour)}:${_two(_selectedTime!.minute)}',
                  style: const TextStyle(color: Colors.white)),
              onTap: _pickTime,
              tileColor: const Color(0xFF2A2A2A),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('기간(분)', style: TextStyle(color: Colors.white70)),
                const SizedBox(width: 12),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF2A2A2A),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: TextFormField(
                      initialValue: _duration.toString(),
                      keyboardType: TextInputType.number,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(border: InputBorder.none),
                      onChanged: (v) {
                        final n = int.tryParse(v);
                        if (n != null && n > 0 && n <= 360) _duration = n;
                      },
                    ),
                  ),
                ),
              ],
            )
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('취소', style: TextStyle(color: Colors.white70)),
        ),
        TextButton(
          onPressed: _save,
          child: const Text('추가', style: TextStyle(color: Colors.white)),
          style: TextButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
        ),
      ],
    );
  }

  Future<void> _pickStudent() async {
    // 재사용: 학생 검색 다이얼로그
    final student = await showDialog<dynamic>(
      context: context,
      barrierDismissible: true,
      builder: (context) => const _StudentPickerProxy(),
    );
    if (student is Map<String, String>) {
      setState(() {
        _studentId = student['id'];
        _studentName = student['name'];
      });
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.dark(primary: Color(0xFF1976D2)),
          dialogBackgroundColor: const Color(0xFF18181A),
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _selectedDate = picked);
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _selectedTime ?? const TimeOfDay(hour: 16, minute: 0),
      builder: (BuildContext context, Widget? child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme(
              brightness: Brightness.dark,
              primary: Color(0xFF1976D2),
              onPrimary: Colors.white,
              secondary: Color(0xFF1976D2),
              onSecondary: Colors.white,
              error: Color(0xFFB00020),
              onError: Colors.white,
              background: Color(0xFF18181A),
              onBackground: Colors.white,
              surface: Color(0xFF18181A),
              onSurface: Colors.white,
            ),
            dialogBackgroundColor: const Color(0xFF18181A),
            timePickerTheme: const TimePickerThemeData(
              backgroundColor: Color(0xFF18181A),
              hourMinuteColor: Color(0xFF1976D2),
              hourMinuteTextColor: Colors.white,
              dialHandColor: Color(0xFF1976D2),
              dialBackgroundColor: Color(0xFF18181A),
              entryModeIconColor: Color(0xFF1976D2),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(24))
              ),
              helpTextStyle: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              dayPeriodTextColor: Colors.white,
              dayPeriodColor: Color(0xFF1976D2),
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) setState(() => _selectedTime = picked);
  }

  Future<void> _save() async {
    if (_studentId == null || _selectedDate == null || _selectedTime == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('학생/날짜/시간을 선택해 주세요'),
        backgroundColor: Color(0xFFE53E3E),
      ));
      return;
    }
    final dt = DateTime(_selectedDate!.year, _selectedDate!.month, _selectedDate!.day, _selectedTime!.hour, _selectedTime!.minute);
    final ov = SessionOverride(
      studentId: _studentId!,
      overrideType: OverrideType.add,
      status: OverrideStatus.planned,
      replacementClassDateTime: dt,
      durationMinutes: _duration,
      reason: OverrideReason.makeup,
    );
    try {
      await DataManager.instance.addSessionOverride(ov);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('보강 저장 실패: $e'),
        backgroundColor: const Color(0xFFE53E3E),
      ));
    }
  }

  String _two(int n) => n.toString().padLeft(2, '0');
}

// StudentSearchDialog를 직접 의존하지 않고 간접 프록시로 호출
class _StudentPickerProxy extends StatelessWidget {
  const _StudentPickerProxy();
  @override
  Widget build(BuildContext context) {
    return _ProxyContent(onPicked: (id, name) => Navigator.of(context).pop({'id': id, 'name': name}));
  }
}

class _ProxyContent extends StatefulWidget {
  final void Function(String id, String name) onPicked;
  const _ProxyContent({required this.onPicked});
  @override
  State<_ProxyContent> createState() => _ProxyContentState();
}

class _ProxyContentState extends State<_ProxyContent> {
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      content: SizedBox(
        width: 520,
        height: 540,
        child: Padding(
          padding: const EdgeInsets.only(top: 24),
          child: _StudentList(onPicked: widget.onPicked),
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

class _StudentList extends StatefulWidget {
  final void Function(String id, String name) onPicked;
  const _StudentList({required this.onPicked});
  @override
  State<_StudentList> createState() => _StudentListState();
}

class _StudentListState extends State<_StudentList> {
  String _query = '';
  @override
  Widget build(BuildContext context) {
    final students = DataManager.instance.students
        .where((s) => _query.isEmpty || s.student.name.contains(_query) || s.student.school.contains(_query))
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          decoration: const InputDecoration(
            hintText: '학생 이름/학교 검색',
            hintStyle: TextStyle(color: Colors.white54),
            prefixIcon: Icon(Icons.search, color: Colors.white70),
            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
            focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
          ),
          style: const TextStyle(color: Colors.white),
          onChanged: (v) => setState(() => _query = v),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: ListView.separated(
            itemCount: students.length,
            separatorBuilder: (_, __) => const Divider(color: Colors.white12, height: 1),
            itemBuilder: (context, idx) {
              final si = students[idx];
              return ListTile(
                title: Text(si.student.name, style: const TextStyle(color: Colors.white)),
                subtitle: Text('${si.student.school} / ${si.student.grade}학년', style: const TextStyle(color: Colors.white70)),
                onTap: () => widget.onPicked(si.student.id, si.student.name),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final Color color;
  const _Badge({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}

class _MakeupEditDialog extends StatefulWidget {
  final SessionOverride item;
  const _MakeupEditDialog({required this.item});

  @override
  State<_MakeupEditDialog> createState() => _MakeupEditDialogState();
}

class _MakeupEditDialogState extends State<_MakeupEditDialog> {
  DateTime? _dateOriginal;
  TimeOfDay? _timeOriginal;
  DateTime? _dateReplacement;
  TimeOfDay? _timeReplacement;
  int _duration = 50;

  @override
  void initState() {
    super.initState();
    _duration = widget.item.durationMinutes ?? DataManager.instance.academySettings.lessonDuration;
    if (widget.item.originalClassDateTime != null) {
      final dt = widget.item.originalClassDateTime!;
      _dateOriginal = DateTime(dt.year, dt.month, dt.day);
      _timeOriginal = TimeOfDay(hour: dt.hour, minute: dt.minute);
    }
    if (widget.item.replacementClassDateTime != null) {
      final dt = widget.item.replacementClassDateTime!;
      _dateReplacement = DateTime(dt.year, dt.month, dt.day);
      _timeReplacement = TimeOfDay(hour: dt.hour, minute: dt.minute);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      title: const Text('보강 편집', style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // original
            if (widget.item.overrideType != OverrideType.add)
              Column(
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text('원본 일정', style: TextStyle(color: Colors.white70)),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: ListTile(
                          leading: const Icon(Icons.calendar_today, color: Colors.white70),
                          title: Text(
                            _dateOriginal == null ? '날짜 선택' : _fmtDate(_dateOriginal!),
                            style: const TextStyle(color: Colors.white),
                          ),
                          onTap: () => _pickDate(isReplacement: false),
                          tileColor: const Color(0xFF2A2A2A),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ListTile(
                          leading: const Icon(Icons.access_time, color: Colors.white70),
                          title: Text(
                            _timeOriginal == null ? '시간 선택' : _fmtTime(_timeOriginal!),
                            style: const TextStyle(color: Colors.white),
                          ),
                          onTap: () => _pickTime(isReplacement: false),
                          tileColor: const Color(0xFF2A2A2A),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            // replacement
            Column(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('대체 일정', style: TextStyle(color: Colors.white70)),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: ListTile(
                        leading: const Icon(Icons.calendar_today, color: Colors.white70),
                        title: Text(
                          _dateReplacement == null ? '날짜 선택' : _fmtDate(_dateReplacement!),
                          style: const TextStyle(color: Colors.white),
                        ),
                        onTap: () => _pickDate(isReplacement: true),
                        tileColor: const Color(0xFF2A2A2A),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ListTile(
                        leading: const Icon(Icons.access_time, color: Colors.white70),
                        title: Text(
                          _timeReplacement == null ? '시간 선택' : _fmtTime(_timeReplacement!),
                          style: const TextStyle(color: Colors.white),
                        ),
                        onTap: () => _pickTime(isReplacement: true),
                        tileColor: const Color(0xFF2A2A2A),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('기간(분)', style: TextStyle(color: Colors.white70)),
                const SizedBox(width: 12),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(color: const Color(0xFF2A2A2A), borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: TextFormField(
                      initialValue: _duration.toString(),
                      keyboardType: TextInputType.number,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(border: InputBorder.none),
                      onChanged: (v) {
                        final n = int.tryParse(v);
                        if (n != null && n > 0 && n <= 360) _duration = n;
                      },
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('닫기', style: TextStyle(color: Colors.white70)),
        ),
        TextButton(
          onPressed: _save,
          child: const Text('저장', style: TextStyle(color: Colors.white)),
          style: TextButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
        ),
      ],
    );
  }

  Future<void> _pickDate({required bool isReplacement}) async {
    final base = isReplacement ? _dateReplacement : _dateOriginal;
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: base ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.dark(primary: Color(0xFF1976D2)),
          dialogBackgroundColor: const Color(0xFF18181A),
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() {
      if (isReplacement) _dateReplacement = picked; else _dateOriginal = picked;
    });
  }

  Future<void> _pickTime({required bool isReplacement}) async {
    final base = isReplacement ? _timeReplacement : _timeOriginal;
    final picked = await showTimePicker(
      context: context,
      initialTime: base ?? const TimeOfDay(hour: 16, minute: 0),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.dark(primary: Color(0xFF1976D2)),
          dialogBackgroundColor: const Color(0xFF18181A),
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() {
      if (isReplacement) _timeReplacement = picked; else _timeOriginal = picked;
    });
  }

  Future<void> _save() async {
    // 유효성: replacement는 반드시 있어야 함
    if (_dateReplacement == null || _timeReplacement == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('대체 일정의 날짜와 시간을 선택하세요.'),
        backgroundColor: Color(0xFFE53E3E),
      ));
      return;
    }
    DateTime? original;
    if (widget.item.overrideType != OverrideType.add) {
      if (_dateOriginal == null || _timeOriginal == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('원본 일정을 선택하세요.'),
          backgroundColor: Color(0xFFE53E3E),
        ));
        return;
      }
      original = DateTime(
        _dateOriginal!.year, _dateOriginal!.month, _dateOriginal!.day,
        _timeOriginal!.hour, _timeOriginal!.minute,
      );
    }
    final replacement = DateTime(
      _dateReplacement!.year, _dateReplacement!.month, _dateReplacement!.day,
      _timeReplacement!.hour, _timeReplacement!.minute,
    );

    final updated = widget.item.copyWith(
      originalClassDateTime: original ?? widget.item.originalClassDateTime,
      replacementClassDateTime: replacement,
      durationMinutes: _duration,
      updatedAt: DateTime.now(),
    );
    Navigator.of(context).pop(updated);
  }

  String _fmtDate(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';
  String _fmtTime(TimeOfDay t) => '${_two(t.hour)}:${_two(t.minute)}';
  String _two(int n) => n.toString().padLeft(2, '0');
}


