import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../models/academic_season.dart';

class TimetableHeader extends StatefulWidget {
  final Function(DateTime) onDateChanged;
  final DateTime selectedDate;
  final int? selectedDayIndex;
  final Function(int) onDaySelected;
  final bool isRegistrationMode;
  final bool isClassListSheetOpen;
  final VoidCallback? onClassListSheetToggle;
  final VoidCallback? onExportPressed;
  final bool showSeasonChip;
  final VoidCallback? onRoadmapPressed;

  const TimetableHeader({
    Key? key,
    required this.onDateChanged,
    required this.selectedDate,
    this.selectedDayIndex,
    required this.onDaySelected,
    this.isRegistrationMode = false,
    this.isClassListSheetOpen = false,
    this.onClassListSheetToggle,
    this.onExportPressed,
    this.showSeasonChip = false,
    this.onRoadmapPressed,
  }) : super(key: key);

  @override
  State<TimetableHeader> createState() => _TimetableHeaderState();
}

class _TimetableHeaderState extends State<TimetableHeader> {
  int _selectedSegment = 0; // 0: 모든, 1: 학년, 2: 학교, 3: 그룹
  static const Color _kNowIndicator = Color(0xFF33A373);
  bool _isSameYmd(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  List<DateTime> _getWeekDays() {
    final monday = widget.selectedDate
        .subtract(Duration(days: widget.selectedDate.weekday - 1));
    return List.generate(7, (index) => monday.add(Duration(days: index)));
  }

  int _getWeekOfMonth(DateTime date) {
    // 월 기준 주차 (월요일 시작)
    final firstDayOfMonth = DateTime(date.year, date.month, 1);
    final firstDayWeekday = firstDayOfMonth.weekday; // Mon=1..Sun=7
    final offset = firstDayWeekday - 1; // 월요일=0
    final weekNumber = ((date.day - 1 + offset) / 7).floor() + 1;
    return weekNumber;
  }

  DateTime _getWeekStart(DateTime date) {
    final monday = date.subtract(Duration(days: date.weekday - 1));
    return DateTime(monday.year, monday.month, monday.day);
  }

  DateTime _getWeekEnd(DateTime date) {
    final start = _getWeekStart(date);
    final end = start.add(const Duration(days: 6));
    return DateTime(end.year, end.month, end.day);
  }

  String _formatWeekRange(DateTime date) {
    final s = _getWeekStart(date);
    final e = _getWeekEnd(date);
    return '${s.month}월 ${s.day}일 ~ ${e.month}월 ${e.day}일';
  }

  String _getWeekdayName(int weekday) {
    const weekdays = ['월', '화', '수', '목', '금', '토', '일'];
    return weekdays[weekday - 1];
  }

  String _formatDate(DateTime date) {
    return '${date.year}년 ${date.month}월 ${date.day}일';
  }

  // (삭제됨) 추가 수업 점 표시는 학생 달력에서만 처리합니다.

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 0, right: 0, top: 0, bottom: 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (widget.showSeasonChip) ...[
                _SeasonChip(
                  season: AcademicSeason.fromDate(widget.selectedDate),
                ),
                const SizedBox(width: 12),
              ],
              Text(
                '${widget.selectedDate.month}월',
                style: TextStyle(
                  color: Colors.grey.shade300,
                  fontSize: 54 * 0.9,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              if (widget.onRoadmapPressed != null) ...[
                _RoadmapButton(onPressed: widget.onRoadmapPressed),
                const SizedBox(width: 8),
              ],
              SizedBox(
                width: 48,
                height: 48,
                child: IconButton(
                  tooltip: '엑셀 내보내기',
                  onPressed: widget.onExportPressed,
                  // ✅ 20% 확대
                  icon: const Icon(Symbols.output,
                      color: Colors.white70, size: 26),
                  splashRadius: 22,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
              ),
              const SizedBox(width: 6),
              Tooltip(
                message: '수업',
                waitDuration: const Duration(milliseconds: 200),
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(24),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(24),
                    hoverColor: Colors.white.withOpacity(0.06),
                    highlightColor: Colors.white.withOpacity(0.04),
                    splashColor: Colors.white.withOpacity(0.10),
                    onTap: widget.onClassListSheetToggle,
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: Icon(
                        Symbols.flight,
                        color: widget.isClassListSheetOpen
                            ? const Color(0xFFEAF2F2)
                            : Colors.white70,
                        size: 26,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Container(
                height: 48,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2A2A),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Tooltip(
                  message: _formatWeekRange(widget.selectedDate),
                  waitDuration: const Duration(milliseconds: 200),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '이전 주',
                        onPressed: () {
                          final newDate = widget.selectedDate
                              .subtract(const Duration(days: 7));
                          widget.onDateChanged(newDate);
                        },
                        icon: const Icon(Icons.chevron_left,
                            color: Colors.white70, size: 22),
                        splashRadius: 18,
                        padding: EdgeInsets.zero,
                        constraints:
                            const BoxConstraints(minWidth: 32, minHeight: 32),
                      ),
                      const SizedBox(width: 4),
                      InkWell(
                        onTap: () {
                          widget.onDateChanged(DateTime.now());
                        },
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6.0, vertical: 2.0),
                          child: Text(
                            '${_getWeekOfMonth(widget.selectedDate)}주차',
                            style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 18,
                                fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        tooltip: '다음 주',
                        onPressed: () {
                          final newDate =
                              widget.selectedDate.add(const Duration(days: 7));
                          widget.onDateChanged(newDate);
                        },
                        icon: const Icon(Icons.chevron_right,
                            color: Colors.white70, size: 22),
                        splashRadius: 18,
                        padding: EdgeInsets.zero,
                        constraints:
                            const BoxConstraints(minWidth: 32, minHeight: 32),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        tooltip: '날짜 선택',
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: widget.selectedDate,
                            firstDate: DateTime(2020, 1, 1),
                            lastDate: DateTime.now()
                                .add(const Duration(days: 365 * 3)),
                            builder: (context, child) {
                              return Theme(
                                data: Theme.of(context).copyWith(
                                  colorScheme: const ColorScheme.dark(
                                      primary: Color(0xFF1976D2)),
                                ),
                                child: child!,
                              );
                            },
                          );
                          if (picked != null) {
                            widget.onDateChanged(picked);
                          }
                        },
                        icon: const Icon(Icons.calendar_today,
                            color: Colors.white70, size: 22),
                        splashRadius: 18,
                        padding: EdgeInsets.zero,
                        constraints:
                            const BoxConstraints(minWidth: 32, minHeight: 32),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _SeasonChip extends StatelessWidget {
  final AcademicSeason season;

  const _SeasonChip({required this.season});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: season.displayName,
      waitDuration: const Duration(milliseconds: 200),
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: const Color(0xFF16201D),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
              color: const Color(0xFF33A373).withValues(alpha: 0.55)),
        ),
        alignment: Alignment.center,
        child: Text(
          season.shortLabel,
          style: const TextStyle(
            color: Color(0xFFEAF2F2),
            fontSize: 16,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );
  }
}

class _RoadmapButton extends StatelessWidget {
  final VoidCallback? onPressed;

  const _RoadmapButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '시즌 로드맵',
      waitDuration: const Duration(milliseconds: 200),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(20),
          hoverColor: Colors.white.withValues(alpha: 0.06),
          highlightColor: Colors.white.withValues(alpha: 0.04),
          splashColor: Colors.white.withValues(alpha: 0.10),
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: const Color(0xFF2A2A2A),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Symbols.route, color: Colors.white70, size: 20),
                SizedBox(width: 6),
                Text(
                  '로드맵',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
