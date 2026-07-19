import 'package:flutter/material.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../services/student_api.dart';

const double _railWidth = 84;
const double _iconSize = 35.2;
const double _highlightWidth = 67.8;
const double _highlightHeight = 38.7;
const double _destinationVerticalPadding = 16;
const Color _lightHighlight = Color(0xB8CFCFCF);
const Color _darkHighlight = Color(0x9A383838);
const Color _lightIcon = Color(0xFF1F2933);
const Color _lightSelectedIcon = Color(0xFF060B12);
const Color _darkIcon = Color(0xFFEAF2F2);
const Color _darkSelectedIcon = Color(0xFFFFFFFF);

class StudentNavigationRail extends StatelessWidget {
  const StudentNavigationRail({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  static const _destinations = <_StudentDestination>[
    _StudentDestination(
      tooltip: '홈',
      icon: Icons.home_outlined,
      selectedIcon: Icons.home_rounded,
    ),
    _StudentDestination(
      tooltip: '교재 풀기',
      icon: Icons.edit_note_outlined,
      selectedIcon: Icons.edit_note_rounded,
    ),
    _StudentDestination(
      tooltip: '내 정보',
      icon: Icons.person_outline_rounded,
      selectedIcon: Icons.person_rounded,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    final iconColor = isDark ? _darkIcon : _lightIcon;
    final selectedIconColor = isDark ? _darkSelectedIcon : _lightSelectedIcon;
    final highlightColor = isDark ? _darkHighlight : _lightHighlight;

    return SizedBox(
      width: _railWidth,
      child: ColoredBox(
        color: context.yggSurfaceBase,
        child: Column(
          children: [
            const SizedBox(height: 16),
            Expanded(
              child: Column(
                children: [
                  for (var index = 0; index < _destinations.length; index++)
                    _DestinationButton(
                      destination: _destinations[index],
                      selected: selectedIndex == index,
                      iconColor: iconColor,
                      selectedIconColor: selectedIconColor,
                      highlightColor: highlightColor,
                      onTap: () => onDestinationSelected(index),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 32),
              child: _StudentAccountButton(
                iconColor: iconColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StudentAccountButton extends StatefulWidget {
  const _StudentAccountButton({required this.iconColor});

  final Color iconColor;

  @override
  State<_StudentAccountButton> createState() => _StudentAccountButtonState();
}

class _StudentAccountButtonState extends State<_StudentAccountButton> {
  late Future<StudentInfo?> _infoFuture;

  @override
  void initState() {
    super.initState();
    _infoFuture = StudentApi.instance.getInfo();
  }

  Future<void> _openAccount() async {
    StudentInfo? info;
    try {
      info = await _infoFuture;
    } catch (_) {
      // 계정 정보 조회가 실패해도 로그아웃은 제공한다.
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => _StudentAccountDialog(info: info),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '계정',
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: _openAccount,
        child: FutureBuilder<StudentInfo?>(
          future: _infoFuture,
          builder: (context, snapshot) {
            final name = snapshot.data?.name.trim() ?? '';
            return CircleAvatar(
              radius: 20,
              backgroundColor:
                  YggGlassTokens.confirmActionColor.withValues(alpha: 0.14),
              foregroundColor: YggGlassTokens.confirmActionColor,
              child: name.isEmpty
                  ? Icon(Icons.person_rounded,
                      color: widget.iconColor, size: 22)
                  : Text(
                      name.characters.first,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
            );
          },
        ),
      ),
    );
  }
}

class _StudentAccountDialog extends StatefulWidget {
  const _StudentAccountDialog({required this.info});

  final StudentInfo? info;

  @override
  State<_StudentAccountDialog> createState() => _StudentAccountDialogState();
}

class _StudentAccountDialogState extends State<_StudentAccountDialog> {
  bool _busy = false;

  Future<void> _signOut() async {
    setState(() => _busy = true);
    try {
      await StudentApi.instance.signOut();
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('로그아웃에 실패했어요.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final grade = info?.grade == null ? '' : ' · ${info!.grade}학년';
    return AlertDialog(
      title: const Text(
        '계정',
        style: TextStyle(fontWeight: FontWeight.w800),
      ),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CircleAvatar(
              radius: 32,
              backgroundColor:
                  YggGlassTokens.confirmActionColor.withValues(alpha: 0.14),
              foregroundColor: YggGlassTokens.confirmActionColor,
              child: Text(
                info?.name.trim().isNotEmpty == true
                    ? info!.name.trim().characters.first
                    : '?',
                style:
                    const TextStyle(fontSize: 23, fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              info?.name ?? '학생 계정',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
            if (info != null) ...[
              const SizedBox(height: 5),
              Text(
                '${info.school}$grade',
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).hintColor),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _busy ? null : _signOut,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1976D2),
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(44),
              ),
              icon: _busy
                  ? const YggLoadingIndicator(size: 18)
                  : const Icon(Icons.logout_rounded),
              label: const Text(
                '로그아웃',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DestinationButton extends StatelessWidget {
  const _DestinationButton({
    required this.destination,
    required this.selected,
    required this.iconColor,
    required this.selectedIconColor,
    required this.highlightColor,
    required this.onTap,
  });

  final _StudentDestination destination;
  final bool selected;
  final Color iconColor;
  final Color selectedIconColor;
  final Color highlightColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final icon = Icon(
      selected ? destination.selectedIcon : destination.icon,
      size: _iconSize,
      color: selected ? selectedIconColor : iconColor,
    );
    return Semantics(
      button: true,
      selected: selected,
      label: destination.tooltip,
      child: Tooltip(
        message: destination.tooltip,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: _destinationVerticalPadding,
            ),
            child: SizedBox(
              width: _highlightWidth,
              height: _highlightHeight,
              child: selected
                  ? DecoratedBox(
                      decoration: BoxDecoration(
                        color: highlightColor,
                        borderRadius:
                            BorderRadius.circular(_highlightHeight / 2),
                      ),
                      child: Center(child: icon),
                    )
                  : Center(child: icon),
            ),
          ),
        ),
      ),
    );
  }
}

class _StudentDestination {
  const _StudentDestination({
    required this.tooltip,
    required this.icon,
    required this.selectedIcon,
  });

  final String tooltip;
  final IconData icon;
  final IconData selectedIcon;
}
