import 'dart:async';
import 'package:flutter/material.dart';
import '../../../services/data_manager.dart';
import '../../../models/session_override.dart';

class MakeupView extends StatefulWidget {
  const MakeupView({super.key});

  @override
  State<MakeupView> createState() => _MakeupViewState();
}

class _MakeupViewState extends State<MakeupView> {
  int _segmentIndex = 0; // 0: 예정, 1: 삭제
  late DateTime _selectedMonthStart; // 리스트 상단 월 선택(시작 월)

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selectedMonthStart = DateTime(now.year, now.month, 1);
    // 다이얼로그가 열릴 때 최신 보강 목록을 즉시 새로고침
    Future.microtask(() => DataManager.instance.loadSessionOverrides());
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0B1112),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(26, 26, 26, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(context),
            const SizedBox(height: 16),
            Expanded(child: _buildContent()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: SizedBox(
        height: 48,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.max,
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
                    icon: const Icon(Icons.arrow_back, color: Colors.white70, size: 20),
                    onPressed: () => Navigator.of(context).maybePop(),
                    tooltip: '닫기',
                    padding: EdgeInsets.zero,
                  ),
                ),
                const Text(
                  '보강 관리',
                  style: TextStyle(
                    color: Color(0xFFEAF2F2),
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            Center(child: _buildModeTabs()),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    return ValueListenableBuilder<List<SessionOverride>>(
      valueListenable: DataManager.instance.sessionOverridesNotifier,
      builder: (context, overrides, _) {
        // 보강(reason: makeup)만 대상으로 함
        final makeups = overrides
            .where((o) => o.reason == OverrideReason.makeup)
            .toList();

        final Widget body = _segmentIndex == 0
            ? _buildScheduledList(makeups)
            : _buildDeletedList(makeups);

        // 전체 영역을 채워 hit-test 누락을 방지
        return SizedBox.expand(child: body);
      },
    );
  }

  Widget _buildModeTabs() {
    const double height = 36;
    const tabs = ['예정', '삭제'];
    return SizedBox(
      height: height,
      width: 180,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF151C21),
          borderRadius: BorderRadius.circular(height / 2),
          border: Border.all(color: Colors.transparent),
        ),
        padding: const EdgeInsets.all(3),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final tabWidth = (constraints.maxWidth - 6) / tabs.length;
            return Stack(
              children: [
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  left: _segmentIndex * tabWidth,
                  top: 0,
                  bottom: 0,
                  width: tabWidth,
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF1B6B63),
                      borderRadius: BorderRadius.circular(14),
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
                    final i = entry.key;
                    final label = entry.value;
                    final selected = _segmentIndex == i;
                    return GestureDetector(
                      onTap: () => setState(() => _segmentIndex = i),
                      behavior: HitTestBehavior.translucent,
                      child: SizedBox(
                        width: tabWidth,
                        child: Center(
                          child: AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 180),
                            style: TextStyle(
                              color: selected ? Colors.white : const Color(0xFF7E8A8A),
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
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

  Widget _buildScheduledList(List<SessionOverride> makeups) {
    DateTime monthStart = _selectedMonthStart;
    final nowForFilter = DateTime.now();
    final bool isThisMonth = monthStart.year == nowForFilter.year && monthStart.month == nowForFilter.month;
    final DateTime monthEnd = DateTime(monthStart.year, monthStart.month + 1, 1);

    final rows = makeups.where((o) {
      final dt = o.replacementClassDateTime;
      if (dt == null) return false;
      if (o.status == OverrideStatus.canceled) return false;
      if (isThisMonth) {
        return !dt.isBefore(monthStart);
      } else {
        return !dt.isBefore(monthStart) && dt.isBefore(monthEnd);
      }
    }).toList()
      ..sort((a, b) {
        final aTime = a.replacementClassDateTime ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bTime = b.replacementClassDateTime ?? DateTime.fromMillisecondsSinceEpoch(0);
        return aTime.compareTo(bTime);
      });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _MonthToolbar(
                monthStart: monthStart,
                onPrev: () => setState(() {
                  _selectedMonthStart = DateTime(monthStart.year, monthStart.month - 1, 1);
                }),
                onNext: () => setState(() {
                  _selectedMonthStart = DateTime(monthStart.year, monthStart.month + 1, 1);
                }),
                onPickMonth: (picked) => setState(() {
                  _selectedMonthStart = DateTime(picked.year, picked.month, 1);
                }),
                compact: true,
              ),
            ),
            const SizedBox(width: 12),
            ElevatedButton.icon(
              onPressed: _onAddMakeupPressed,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('추가 수업', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1B6B63),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                minimumSize: const Size(0, 40),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Expanded(
          child: rows.isEmpty
              ? const Center(
                  child: Text('항목이 없습니다', style: TextStyle(color: Colors.white38, fontSize: 16)),
                )
              : ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final item = rows[index];
                    final isCompleted = item.status == OverrideStatus.completed;
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Opacity(
                            opacity: isCompleted ? 0.45 : 1.0,
                            child: _PlannedTile(number: index + 1, item: item),
                          ),
                        ),
                        const SizedBox(width: 16),
                        SizedBox(
                          width: 96,
                          child: isCompleted ? _CompletedTile(item: item) : const SizedBox.shrink(),
                        ),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildDeletedList(List<SessionOverride> makeups) {
    final canceled = makeups
        .where((o) => o.status == OverrideStatus.canceled)
        .toList()
      ..sort((a, b) {
        final aTime = a.replacementClassDateTime ?? a.originalClassDateTime ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bTime = b.replacementClassDateTime ?? b.originalClassDateTime ?? DateTime.fromMillisecondsSinceEpoch(0);
        return aTime.compareTo(bTime);
      });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _MonthToolbar(
                monthStart: _selectedMonthStart,
                onPrev: () => setState(() {
                  _selectedMonthStart = DateTime(_selectedMonthStart.year, _selectedMonthStart.month - 1, 1);
                }),
                onNext: () => setState(() {
                  _selectedMonthStart = DateTime(_selectedMonthStart.year, _selectedMonthStart.month + 1, 1);
                }),
                onPickMonth: (picked) => setState(() {
                  _selectedMonthStart = DateTime(picked.year, picked.month, 1);
                }),
                compact: true,
              ),
            ),
            const SizedBox(width: 12),
            ElevatedButton.icon(
              onPressed: _onAddMakeupPressed,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('추가 수업', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1B6B63),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                minimumSize: const Size(0, 40),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Expanded(
          child: canceled.isEmpty
              ? const Center(
                  child: Text('삭제된 항목이 없습니다', style: TextStyle(color: Colors.white38, fontSize: 16)),
                )
              : ListView.separated(
                  itemCount: canceled.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, idx) {
                    final item = canceled[idx];
                    return _OverrideTile(item: item);
                  },
                ),
        ),
      ],
    );
  }
}

class _MonthToolbar extends StatelessWidget {
  final DateTime monthStart;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final ValueChanged<DateTime>? onPickMonth;

  const _MonthToolbar({
    required this.monthStart,
    required this.onPrev,
    required this.onNext,
    this.onPickMonth,
    this.compact = false,
  });

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final yearMonth = '${monthStart.year}.${monthStart.month.toString().padLeft(2, '0')}';

    final baseTextStyle = TextStyle(
      color: const Color(0xFFEAF2F2),
      fontSize: compact ? 18 : 24,
      fontWeight: FontWeight.bold,
    );

    return Row(
      mainAxisSize: MainAxisSize.max,
      children: [
        IconButton(
          onPressed: onPrev,
          icon: const Icon(Icons.chevron_left, color: Colors.white70),
          tooltip: '이전 달',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        ),
        const SizedBox(width: 10),
        GestureDetector(
          onTap: () {
            final now = DateTime.now();
            onPickMonth?.call(DateTime(now.year, now.month, 1));
          },
          child: SizedBox(
            width: 86,
            child: Center(child: Text(yearMonth, style: baseTextStyle)),
          ),
        ),
        const SizedBox(width: 10),
        IconButton(
          onPressed: onNext,
          icon: const Icon(Icons.chevron_right, color: Colors.white70),
          tooltip: '다음 달',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        ),
        const SizedBox(width: 8),
        IconButton(
          onPressed: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate: monthStart,
              firstDate: DateTime(2000),
              lastDate: DateTime(2100),
              builder: (context, child) => Theme(
                data: Theme.of(context).copyWith(
                  colorScheme: const ColorScheme.dark(primary: Color(0xFF1976D2)),
                  dialogBackgroundColor: const Color(0xFF1F1F1F),
                ),
                child: child!,
              ),
            );
            if (picked != null) onPickMonth?.call(picked);
          },
          icon: const Icon(Icons.date_range, size: 20, color: Colors.white54),
          padding: EdgeInsets.zero,
          tooltip: '달력',
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        ),
      ],
    );
  }
}

// 기존 Tile 클래스들은 스타일 개선하여 유지
class _PlannedTile extends StatelessWidget {
  final int number;
  final SessionOverride item;
  const _PlannedTile({required this.number, required this.item});

  String _fmt(DateTime d) => '${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final repl = item.replacementClassDateTime;
    final orig = item.originalClassDateTime;
    final duration = item.durationMinutes ?? DataManager.instance.academySettings.lessonDuration;
    final makeupText = repl != null ? _fmt(repl) : '-';
    final origText = orig != null ? _fmt(orig) : '-';
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 12, 12, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A2325),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      constraints: const BoxConstraints(minHeight: 96),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  DataManager.instance.students.firstWhere((s) => s.student.id == item.studentId, orElse: () => DataManager.instance.students.first).student.name,
                  style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Row(
                children: [
                  _ActionButton(
                    icon: Icons.edit,
                    tooltip: '수정',
                    onTap: () async {
                      final updated = await showDialog<SessionOverride>(
                        context: context,
                        builder: (_) => _MakeupEditDialog(item: item),
                      );
                      if (updated != null) {
                        await DataManager.instance.updateSessionOverride(updated);
                      }
                    },
                  ),
                  const SizedBox(width: 8),
                  _ActionButton(
                    icon: Icons.delete_outline,
                    tooltip: '삭제',
                    color: const Color(0xFFE57373),
                    onTap: () async {
                      await DataManager.instance.cancelSessionOverride(item.id);
                    },
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                makeupText,
                style: const TextStyle(color: Color(0xFF33A373), fontSize: 18, fontWeight: FontWeight.w700),
              ),
              if (orig != null) ...[
                const SizedBox(width: 10),
                const Icon(Icons.arrow_back_ios_new, size: 15, color: Colors.white60),
                const SizedBox(width: 10),
                Text(
                  origText,
                  style: const TextStyle(color: Colors.white70, fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ],
              const Spacer(),
              Text('기간: ${duration}분', style: const TextStyle(color: Colors.white54, fontSize: 13)),
            ],
          ),
        ],
      ),
    );
  }
}

class _CompletedTile extends StatelessWidget {
  final SessionOverride item;
  const _CompletedTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final bool isAbsent = item.status == OverrideStatus.canceled;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF0B1112),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.transparent),
        boxShadow: const [],
      ),
      constraints: const BoxConstraints(minHeight: 96),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                isAbsent ? Icons.close : Icons.check,
                color: isAbsent ? const Color(0xFFE57373) : const Color(0xFF4CAF50),
                size: 22,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            isAbsent ? '결석' : '출석 완료',
            style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _OverrideTile extends StatelessWidget {
  final SessionOverride item;
  final bool simple;
  const _OverrideTile({required this.item, this.simple = false});

  String _fmt(DateTime d) {
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
           '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final studentName = DataManager.instance.students.firstWhere((s) => s.student.id == item.studentId, orElse: () => DataManager.instance.students.first).student.name;
    final original = item.originalClassDateTime;
    final repl = item.replacementClassDateTime;
    final Color statusColor = item.status == OverrideStatus.canceled ? const Color(0xFFE53E3E) : const Color(0xFF1976D2);

    if (simple) {
      return Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  studentName,
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (item.status == OverrideStatus.planned)
                  Row(
                    children: [
                      _ActionButton(
                        icon: Icons.edit,
                        tooltip: '수정',
                        onTap: () async {
                          final updated = await showDialog<SessionOverride>(
                            context: context,
                            builder: (_) => _MakeupEditDialog(item: item),
                          );
                          if (updated != null) {
                            try {
                              await DataManager.instance.updateSessionOverride(updated);
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                                  content: Text('보강이 수정되었습니다.'),
                                  backgroundColor: Color(0xFF1976D2),
                                ));
                              }
                            } catch (e) {
                              // error handling
                            }
                          }
                        },
                      ),
                      const SizedBox(width: 8),
                      _ActionButton(
                        icon: Icons.delete_outline,
                        tooltip: '취소',
                        color: const Color(0xFFE57373),
                        onTap: () async {
                          await DataManager.instance.cancelSessionOverride(item.id);
                        },
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (repl != null)
              Row(
                children: [
                  const Icon(Icons.access_time, size: 14, color: Color(0xFF64B5F6)),
                  const SizedBox(width: 6),
                  Text(_fmt(repl), style: const TextStyle(color: Colors.white70, fontSize: 14)),
                ],
              ),
            if (item.durationMinutes != null) ...[
              const SizedBox(height: 4),
              Text('${item.durationMinutes}분', style: const TextStyle(color: Colors.white38, fontSize: 12)),
            ],
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(22, 12, 12, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A2325),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      constraints: const BoxConstraints(minHeight: 96),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(studentName, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: statusColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: statusColor.withOpacity(0.3)),
                ),
                child: Text(
                  item.status == OverrideStatus.canceled ? '취소됨' : '예정',
                  style: TextStyle(color: statusColor, fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                repl != null ? _fmt(repl) : '-',
                style: const TextStyle(color: Color(0xFF33A373), fontSize: 18, fontWeight: FontWeight.w700),
              ),
              if (original != null) ...[
                const SizedBox(width: 10),
                const Icon(Icons.arrow_back_ios_new, size: 15, color: Colors.white60),
                const SizedBox(width: 10),
                Text(
                  _fmt(original),
                  style: const TextStyle(color: Colors.white70, fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ],
              const Spacer(),
              if (item.durationMinutes != null)
                Text('기간: ${item.durationMinutes}분', style: const TextStyle(color: Colors.white54, fontSize: 13)),
            ],
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color? color;

  const _ActionButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(6.0),
          child: Icon(icon, size: 18, color: color ?? Colors.white54),
        ),
      ),
    );
  }
}

extension on _MakeupViewState {
  Future<void> _onAddMakeupPressed() async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => const MakeupAddDialog(),
    );
    if (mounted && saved == true) {
      await DataManager.instance.loadSessionOverrides();
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
      title: const Text('추가 수업', style: TextStyle(color: Colors.white, fontSize: 18)),
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
  final bool outlined;
  const _Badge({required this.text, required this.color, this.outlined = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: outlined ? Colors.transparent : color,
        borderRadius: BorderRadius.circular(6),
        border: outlined ? Border.all(color: Colors.grey) : null,
      ),
      child: Text(
        text,
        style: TextStyle(
          color: outlined ? Colors.grey : Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
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
                  child: Text(
                    widget.item.overrideType == OverrideType.add ? '날짜' : '보강 일정',
                    style: TextStyle(color: Colors.white70),
                  ),
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
            )
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소', style: TextStyle(color: Colors.white70)),
        ),
        TextButton(
          onPressed: _save,
          child: const Text('저장', style: TextStyle(color: Colors.white)),
          style: TextButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
        ),
      ],
    );
  }

  String _fmtDate(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  String _fmtTime(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _pickDate({required bool isReplacement}) async {
    final initial = isReplacement ? _dateReplacement : _dateOriginal;
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 1),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.dark(primary: Color(0xFF1976D2)),
          dialogBackgroundColor: const Color(0xFF1F1F1F),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      setState(() {
        if (isReplacement) {
          _dateReplacement = picked;
        } else {
          _dateOriginal = picked;
        }
      });
    }
  }

  Future<void> _pickTime({required bool isReplacement}) async {
    final initial = isReplacement ? _timeReplacement : _timeOriginal;
    final picked = await showTimePicker(
      context: context,
      initialTime: initial ?? const TimeOfDay(hour: 14, minute: 0),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          timePickerTheme: const TimePickerThemeData(
            backgroundColor: Color(0xFF1F1F1F),
            dialHandColor: Color(0xFF1976D2),
            dialBackgroundColor: Color(0xFF2A2A2A),
            hourMinuteTextColor: Colors.white,
            dayPeriodTextColor: Colors.white,
            helpTextStyle: TextStyle(color: Colors.white),
            entryModeIconColor: Color(0xFF1976D2),
          ),
          colorScheme: const ColorScheme.dark(primary: Color(0xFF1976D2), surface: Color(0xFF1F1F1F)),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      setState(() {
        if (isReplacement) {
          _timeReplacement = picked;
        } else {
          _timeOriginal = picked;
        }
      });
    }
  }

  void _save() {
    if (widget.item.overrideType != OverrideType.add) {
      if (_dateOriginal == null || _timeOriginal == null) return;
    }
    if (_dateReplacement == null || _timeReplacement == null) return;

    DateTime? origDt;
    if (widget.item.overrideType != OverrideType.add) {
      origDt = DateTime(
        _dateOriginal!.year, _dateOriginal!.month, _dateOriginal!.day,
        _timeOriginal!.hour, _timeOriginal!.minute,
      );
    }

    final replDt = DateTime(
      _dateReplacement!.year, _dateReplacement!.month, _dateReplacement!.day,
      _timeReplacement!.hour, _timeReplacement!.minute,
    );

    final updated = widget.item.copyWith(
      originalClassDateTime: origDt,
      replacementClassDateTime: replDt,
      durationMinutes: _duration,
    );
    Navigator.of(context).pop(updated);
  }
}

