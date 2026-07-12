import 'package:flutter/material.dart';
import 'package:mneme_flutter/main.dart' show rootNavigatorKey;

import '../../../app_overlays.dart';
import '../../../widgets/solid_capsule_action_bar.dart';
import '../../design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';

int timetableWeekOfMonth(DateTime date) {
  final firstDayOfMonth = DateTime(date.year, date.month, 1);
  final offset = firstDayOfMonth.weekday - 1;
  return ((date.day - 1 + offset) / 7).floor() + 1;
}

String timetableFormatWeekRange(DateTime date) {
  final monday = date.subtract(Duration(days: date.weekday - 1));
  final start = DateTime(monday.year, monday.month, monday.day);
  final end = start.add(const Duration(days: 6));
  return '${start.month}월 ${start.day}일 ~ ${end.month}월 ${end.day}일';
}

/// 시간 메뉴 상단 가운데 주/월 네비게이션 (공용 SolidCapsule 버튼 모음).
/// [yearNavigation]이면 스케줄 캘린더용 월 단위 이동(라벨: YYYY년 M월).
class TimetableWeekNavOverlay {
  OverlayEntry? _entry;
  DateTime _selectedDate = DateTime.now();
  ValueChanged<DateTime>? _onDateChanged;
  BuildContext? _hostContext;
  bool _syncScheduled = false;
  bool _disposed = false;
  bool _sideSheetWidthListening = false;
  bool _yearNavigation = false;

  void _onLeftSideSheetWidthChanged() {
    _entry?.markNeedsBuild();
  }

  void _ensureSideSheetWidthListener() {
    if (_sideSheetWidthListening) return;
    leftSideSheetClipWidthNotifier.addListener(_onLeftSideSheetWidthChanged);
    _sideSheetWidthListening = true;
  }

  void sync(
    BuildContext context, {
    required DateTime selectedDate,
    required ValueChanged<DateTime> onDateChanged,
    bool yearNavigation = false,
  }) {
    if (_disposed) return;
    _ensureSideSheetWidthListener();
    _hostContext = context;
    _selectedDate = selectedDate;
    _onDateChanged = onDateChanged;
    _yearNavigation = yearNavigation;

    if (_syncScheduled) return;
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      if (_disposed || !context.mounted) return;
      final overlay = Overlay.maybeOf(context, rootOverlay: true);
      if (overlay == null) return;

      if (_entry == null) {
        _entry = OverlayEntry(builder: _buildOverlay);
        overlay.insert(_entry!);
      } else {
        _entry!.markNeedsBuild();
      }
    });
  }

  void dispose() {
    _disposed = true;
    if (_sideSheetWidthListening) {
      leftSideSheetClipWidthNotifier
          .removeListener(_onLeftSideSheetWidthChanged);
      _sideSheetWidthListening = false;
    }
    _entry?.remove();
    _entry = null;
    _hostContext = null;
  }

  Future<void> _showDatePicker() async {
    final context = rootNavigatorKey.currentContext ?? _hostContext;
    if (context == null || !context.mounted) return;

    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020, 1, 1),
      lastDate: DateTime.now().add(const Duration(days: 365 * 3)),
      builder: (ctx, child) {
        return Theme(
          data: Theme.of(ctx).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: Color(0xFF1976D2),
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) _onDateChanged?.call(picked);
  }

  Future<void> _showMonthYearPicker() async {
    final context = rootNavigatorKey.currentContext ?? _hostContext;
    if (context == null || !context.mounted) return;

    var year = _selectedDate.year;
    var month = _selectedDate.month;
    final yearOptions =
        List.generate(25, (i) => _selectedDate.year - 12 + i);
    final picked = await showDialog<DateTime>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('년/월 선택'),
              content: SizedBox(
                width: 360,
                child: Row(
                  children: [
                    Expanded(
                      child: DropdownButton<int>(
                        isExpanded: true,
                        value: year,
                        items: yearOptions
                            .map(
                              (y) => DropdownMenuItem(
                                value: y,
                                child: Text('$y년'),
                              ),
                            )
                            .toList(),
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() => year = v);
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButton<int>(
                        isExpanded: true,
                        value: month,
                        items: List.generate(12, (i) => i + 1)
                            .map(
                              (m) => DropdownMenuItem(
                                value: m,
                                child: Text('$m월'),
                              ),
                            )
                            .toList(),
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() => month = v);
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('취소'),
                ),
                FilledButton(
                  onPressed: () =>
                      Navigator.pop(dialogContext, DateTime(year, month, 1)),
                  child: const Text('이동'),
                ),
              ],
            );
          },
        );
      },
    );
    if (picked != null) _onDateChanged?.call(picked);
  }

  DateTime _dateInMonth(int year, int month) {
    final normalized = DateTime(year, month, 1);
    final lastDay =
        DateUtils.getDaysInMonth(normalized.year, normalized.month);
    return DateTime(
      normalized.year,
      normalized.month,
      _selectedDate.day.clamp(1, lastDay),
    );
  }

  Widget _buildOverlay(BuildContext overlayContext) {
    final railWidth = NavigationRailTheme.of(overlayContext).minWidth ??
        FabTabBarTokens.fabBarNavRailDefaultWidth;
    final sideSheetWidth = leftSideSheetClipWidthNotifier.value;
    final weekLabel = '${timetableWeekOfMonth(_selectedDate)}주차';
    final onDateChanged = _onDateChanged ?? (_) {};
    final weekRange = timetableFormatWeekRange(_selectedDate);
    final monthLabel =
        '${_selectedDate.year}년 ${_selectedDate.month}월';

    return Positioned(
      left: railWidth + sideSheetWidth,
      right: 0,
      top: FabTabBarTokens.previewAcademyTopInset - 12,
      child: Center(
        child: SolidCapsuleActionBar(
          itemSpacing: 6,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          children: _yearNavigation
              ? [
                  SolidCapsuleActionButton(
                    tooltip: '이전 달',
                    icon: Icons.chevron_left_rounded,
                    onPressed: () => onDateChanged(
                      _dateInMonth(
                        _selectedDate.year,
                        _selectedDate.month - 1,
                      ),
                    ),
                  ),
                  SolidCapsuleTextActionButton(
                    tooltip: '연도·월 선택',
                    label: monthLabel,
                    onPressed: _showMonthYearPicker,
                  ),
                  SolidCapsuleActionButton(
                    tooltip: '다음 달',
                    icon: Icons.chevron_right_rounded,
                    onPressed: () => onDateChanged(
                      _dateInMonth(
                        _selectedDate.year,
                        _selectedDate.month + 1,
                      ),
                    ),
                  ),
                ]
              : [
                  SolidCapsuleActionButton(
                    tooltip: '이전 주',
                    icon: Icons.chevron_left_rounded,
                    onPressed: () => onDateChanged(
                      _selectedDate.subtract(const Duration(days: 7)),
                    ),
                  ),
                  SolidCapsuleTextActionButton(
                    tooltip: '$weekRange\n오늘로 이동',
                    label: weekLabel,
                    onPressed: () => onDateChanged(DateTime.now()),
                  ),
                  SolidCapsuleActionButton(
                    tooltip: '다음 주',
                    icon: Icons.chevron_right_rounded,
                    onPressed: () => onDateChanged(
                      _selectedDate.add(const Duration(days: 7)),
                    ),
                  ),
                  SolidCapsuleActionButton(
                    tooltip: '날짜 선택',
                    icon: Icons.calendar_today_outlined,
                    onPressed: _showDatePicker,
                  ),
                ],
        ),
      ),
    );
  }
}
