import 'package:flutter/material.dart';

/// 앱 전역에서 사용하는 iOS형 휠 시간 선택 다이얼로그.
///
/// 학원 설정 공용 다이얼로그(`PreviewAcademyDialogSheet`)와 시각적 톤은
/// 맞추되, 시간 피커는 너비가 더 좁아야 하므로 별도 셸로 분리했다.
/// `AppTimePickerDialog.show(...)` 한 줄로 어디서든 호출할 수 있다.
class AppTimePickerDialog extends StatefulWidget {
  final String title;
  final TimeOfDay initialTime;

  const AppTimePickerDialog({
    super.key,
    required this.title,
    required this.initialTime,
  });

  static Future<TimeOfDay?> show({
    required BuildContext context,
    String title = '시간 선택',
    TimeOfDay? initialTime,
  }) {
    return showGeneralDialog<TimeOfDay>(
      context: context,
      barrierDismissible: true,
      barrierLabel: title,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      transitionDuration: const Duration(milliseconds: 280),
      pageBuilder: (context, animation, secondaryAnimation) {
        return AppTimePickerDialog(
          title: title,
          initialTime: initialTime ?? const TimeOfDay(hour: 9, minute: 0),
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curve = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curve,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 1),
              end: Offset.zero,
            ).animate(curve),
            child: child,
          ),
        );
      },
    );
  }

  @override
  State<AppTimePickerDialog> createState() => _AppTimePickerDialogState();
}

class _AppTimePickerDialogState extends State<AppTimePickerDialog> {
  // 다이얼로그 셸
  static const double _kRadius = 34;
  static const double _kMaxWidth = 520; // 공용 템플릿(780)의 2/3
  static const double _kMinHeight = 320;
  static const double _kOuterPaddingH = 24;
  static const double _kBorderInset = 4;
  static const double _kInnerPadTop = 12;
  static const double _kInnerPadH = 16;
  static const double _kInnerPadBottom = 20;
  static const double _kHeaderToBody = 28;
  static const double _kTitleFontSize = 20;

  // 휠 피커
  static const double _kItemExtent = 52;
  static const int _kVisibleRows = 5;
  static const double _kDiameterRatio = 1.5;
  static const double _kSelectedFontSize = 26;
  static const double _kPeriodFontSize = 22;
  /// 분 열만 시 쪽으로 당기는 시각 보정(레이아웃 비율은 유지)
  static const double _kMinuteColumnShiftLeft = 16;

  static const Color _kConfirmColor = Color(0xFF33A373);
  static const String _kValueFontFamily = 'Pretendard';
  static const String _kTitleFontFamily = 'Pretendard';

  // 0 = 오전, 1 = 오후
  late int _periodIndex;
  // 1..12
  late int _hour12;
  // 0..59
  late int _minute;

  late final FixedExtentScrollController _periodController;
  late final FixedExtentScrollController _hourController;
  late final FixedExtentScrollController _minuteController;

  @override
  void initState() {
    super.initState();
    final h = widget.initialTime.hour;
    _periodIndex = h >= 12 ? 1 : 0;
    final h12 = h % 12;
    _hour12 = h12 == 0 ? 12 : h12;
    _minute = widget.initialTime.minute;

    _periodController = FixedExtentScrollController(initialItem: _periodIndex);
    _hourController = FixedExtentScrollController(initialItem: _hour12 - 1);
    _minuteController = FixedExtentScrollController(initialItem: _minute);
  }

  @override
  void dispose() {
    _periodController.dispose();
    _hourController.dispose();
    _minuteController.dispose();
    super.dispose();
  }

  void _close([TimeOfDay? value]) => Navigator.of(context).pop(value);

  void _confirm() {
    final base = _hour12 % 12; // 12 -> 0
    final hour24 = _periodIndex == 1 ? base + 12 : base;
    _close(TimeOfDay(hour: hour24, minute: _minute));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sheetSurface =
        isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7);
    final highlightColor = isDark ? const Color(0xFF2C2C2E) : Colors.white;
    final headerIconBg =
        isDark ? const Color(0xFF3A3A3C) : const Color(0xFFE5E5EA);
    final subtleBorder =
        isDark ? const Color(0x33FFFFFF) : const Color(0x33000000);
    final titleColor = isDark ? Colors.white : const Color(0xFF1C1C1E);
    final selectedColor = isDark ? Colors.white : const Color(0xFF1C1C1E);
    final dimColor =
        isDark ? const Color(0x80FFFFFF) : const Color(0x80000000);

    return Material(
      type: MaterialType.transparency,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: _kMaxWidth,
            minHeight: _kMinHeight,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: _kOuterPaddingH),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: sheetSurface,
                borderRadius: BorderRadius.circular(_kRadius),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 32,
                    offset: Offset(0, 12),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.all(_kBorderInset),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    _kInnerPadH,
                    _kInnerPadTop,
                    _kInnerPadH,
                    _kInnerPadBottom,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        height: 44,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Center(
                              child: Text(
                                widget.title,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontFamily: _kTitleFontFamily,
                                  fontSize: _kTitleFontSize,
                                  fontWeight: FontWeight.w600,
                                  color: titleColor,
                                ),
                              ),
                            ),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: _IconButton(
                              backgroundColor: headerIconBg,
                              borderColor: subtleBorder,
                              icon: Icons.close,
                              iconColor: titleColor,
                              onPressed: () => _close(),
                              ),
                            ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: _ConfirmPill(
                                borderColor: subtleBorder,
                                backgroundColor: _kConfirmColor,
                                onPressed: _confirm,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: _kHeaderToBody),
                      _buildWheels(
                        highlightColor: highlightColor,
                        selectedColor: selectedColor,
                        dimColor: dimColor,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWheels({
    required Color highlightColor,
    required Color selectedColor,
    required Color dimColor,
  }) {
    final pickerHeight = _kItemExtent * _kVisibleRows;

    return SizedBox(
      height: pickerHeight,
      child: Stack(
        alignment: Alignment.center,
        children: [
          IgnorePointer(
            child: Container(
              height: _kItemExtent,
              margin: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: highlightColor,
                borderRadius: BorderRadius.circular(_kItemExtent / 2),
              ),
            ),
          ),
          ShaderMask(
            shaderCallback: (bounds) {
              return const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black,
                  Colors.black,
                  Colors.transparent,
                ],
                stops: [0.0, 0.28, 0.72, 1.0],
              ).createShader(bounds);
            },
            blendMode: BlendMode.dstIn,
            child: Row(
              children: [
                Expanded(
                  flex: 4,
                  child: _WheelColumn(
                    controller: _periodController,
                    itemExtent: _kItemExtent,
                    childCount: 2,
                    selectedIndex: _periodIndex,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 12),
                    fontSize: _kPeriodFontSize,
                    fontFamily: _kValueFontFamily,
                    selectedColor: selectedColor,
                    dimColor: dimColor,
                    labelBuilder: (i) => i == 0 ? '오전' : '오후',
                    onSelectedItemChanged: (i) =>
                        setState(() => _periodIndex = i),
                  ),
                ),
                Expanded(
                  flex: 4,
                  child: _WheelColumn(
                    controller: _hourController,
                    itemExtent: _kItemExtent,
                    childCount: 12,
                    selectedIndex: _hour12 - 1,
                    alignment: Alignment.center,
                    fontSize: _kSelectedFontSize,
                    fontFamily: _kValueFontFamily,
                    selectedColor: selectedColor,
                    dimColor: dimColor,
                    labelBuilder: (i) => '${i + 1}',
                    onSelectedItemChanged: (i) =>
                        setState(() => _hour12 = i + 1),
                  ),
                ),
                Expanded(
                  flex: 4,
                  child: Transform.translate(
                    offset: const Offset(-_kMinuteColumnShiftLeft, 0),
                    child: _WheelColumn(
                      controller: _minuteController,
                      itemExtent: _kItemExtent,
                      childCount: 60,
                      selectedIndex: _minute,
                      alignment: Alignment.center,
                      fontSize: _kSelectedFontSize,
                      fontFamily: _kValueFontFamily,
                      selectedColor: selectedColor,
                      dimColor: dimColor,
                      labelBuilder: (i) => i.toString().padLeft(2, '0'),
                      onSelectedItemChanged: (i) => setState(() => _minute = i),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WheelColumn extends StatelessWidget {
  final FixedExtentScrollController controller;
  final double itemExtent;
  final int childCount;
  final int selectedIndex;
  final Alignment alignment;
  final EdgeInsetsGeometry? padding;
  final double fontSize;
  final String fontFamily;
  final Color selectedColor;
  final Color dimColor;
  final String Function(int index) labelBuilder;
  final ValueChanged<int> onSelectedItemChanged;

  const _WheelColumn({
    required this.controller,
    required this.itemExtent,
    required this.childCount,
    required this.selectedIndex,
    required this.alignment,
    this.padding,
    required this.fontSize,
    required this.fontFamily,
    required this.selectedColor,
    required this.dimColor,
    required this.labelBuilder,
    required this.onSelectedItemChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ListWheelScrollView.useDelegate(
      controller: controller,
      itemExtent: itemExtent,
      diameterRatio: _AppTimePickerDialogState._kDiameterRatio,
      physics: const FixedExtentScrollPhysics(),
      onSelectedItemChanged: onSelectedItemChanged,
      childDelegate: ListWheelChildBuilderDelegate(
        childCount: childCount,
        builder: (context, index) {
          final isSelected = index == selectedIndex;
          return Container(
            alignment: alignment,
            padding: padding,
            child: Text(
              labelBuilder(index),
              style: TextStyle(
                fontFamily: fontFamily,
                fontSize: fontSize,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                color: isSelected ? selectedColor : dimColor,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _IconButton extends StatelessWidget {
  final Color backgroundColor;
  final Color borderColor;
  final IconData icon;
  final Color iconColor;
  final VoidCallback onPressed;

  const _IconButton({
    required this.backgroundColor,
    required this.borderColor,
    required this.icon,
    required this.iconColor,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: backgroundColor,
        border: Border.all(color: borderColor, width: 0.5),
      ),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 36,
            height: 36,
            child: Icon(icon, size: 20, color: iconColor),
          ),
        ),
      ),
    );
  }
}

class _ConfirmPill extends StatelessWidget {
  final Color borderColor;
  final Color backgroundColor;
  final VoidCallback onPressed;

  const _ConfirmPill({
    required this.borderColor,
    required this.backgroundColor,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: borderColor, width: 0.5),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(999),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 18, vertical: 9),
            child: Icon(Icons.check, size: 22, color: Colors.white),
          ),
        ),
      ),
    );
  }
}
