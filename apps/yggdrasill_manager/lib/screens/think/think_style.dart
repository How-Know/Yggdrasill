import 'package:flutter/material.dart';

import '../../widgets/app_navigation_bar.dart' show kNavAccent;

const Color kThinkBg = Color(0xFF1F1F1F);
const Color kThinkPanel = Color(0xFF18181A);
const Color kThinkBorder = Color(0xFF2A2A2A);
const Color kThinkField = Color(0xFF2A2A2A);
const Color kThinkAccent = kNavAccent;
const Color kThinkBlue = Color(0xFF1976D2);
const Color kThinkText = Colors.white;
const Color kThinkSub = Color(0xFFB3B3B3);
const Color kThinkHint = Color(0xFF666666);
const Color kThinkError = Color(0xFFD32F2F);
const Color kThinkSuccess = Color(0xFF2E7D32);
const Color kThinkLink = Color(0xFF64B5F6);
const Color kThinkQuote = Color(0xFF232323);

class ThinkPanel extends StatelessWidget {
  const ThinkPanel({super.key, required this.child, this.padding = EdgeInsets.zero});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: kThinkPanel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kThinkBorder),
      ),
      child: child,
    );
  }
}

class ThinkPillTabs extends StatelessWidget {
  const ThinkPillTabs({
    super.key,
    required this.labels,
    required this.icons,
    required this.selected,
    required this.onSelected,
  });

  final List<String> labels;
  final List<IconData> icons;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: kThinkPanel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kThinkBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < labels.length; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            _PillTab(
              label: labels[i],
              icon: icons[i],
              selected: i == selected,
              onTap: () => onSelected(i),
            ),
          ],
        ],
      ),
    );
  }
}

class _PillTab extends StatelessWidget {
  const _PillTab({required this.label, required this.icon, required this.selected, required this.onTap});

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          constraints: const BoxConstraints(minWidth: 96),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: selected ? kThinkAccent.withValues(alpha: 0.16) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: selected ? Border.all(color: kThinkAccent.withValues(alpha: 0.28)) : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: selected ? kThinkAccent : kThinkSub),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: selected ? kThinkText : kThinkSub,
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ThinkToggleChip extends StatelessWidget {
  const ThinkToggleChip({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onChanged,
    this.tooltip,
    this.enabled = true,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final ValueChanged<bool> onChanged;
  final String? tooltip;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final color = !enabled ? kThinkHint : (selected ? kThinkAccent : kThinkSub);
    final chip = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? () => onChanged(!selected) : null,
        borderRadius: BorderRadius.circular(18),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: selected && enabled ? kThinkAccent.withValues(alpha: 0.16) : Colors.transparent,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: selected && enabled ? kThinkAccent.withValues(alpha: 0.5) : kThinkBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 8),
              Text(label, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
    return tooltip == null ? chip : Tooltip(message: tooltip!, child: chip);
  }
}

class ThinkBadge extends StatelessWidget {
  const ThinkBadge(this.label, {super.key, this.color = kThinkSub});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
    );
  }
}

class ThinkNotice extends StatelessWidget {
  const ThinkNotice({super.key, required this.text, this.color = kThinkBlue, this.icon = Icons.info_outline, this.onClose});

  final String text;
  final Color color;
  final IconData icon;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(child: SelectableText(text, style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.4))),
          if (onClose != null)
            InkWell(
              onTap: onClose,
              borderRadius: BorderRadius.circular(8),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.close, size: 16, color: kThinkSub),
              ),
            ),
        ],
      ),
    );
  }
}

InputDecoration thinkInputDecoration({String? hint, String? label, Widget? prefixIcon, Widget? suffixIcon, bool dense = false}) {
  OutlineInputBorder border(Color c) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: c),
      );
  return InputDecoration(
    hintText: hint,
    labelText: label,
    hintStyle: const TextStyle(color: kThinkHint),
    labelStyle: const TextStyle(color: kThinkSub),
    floatingLabelStyle: const TextStyle(color: kThinkAccent),
    filled: true,
    fillColor: kThinkField,
    isDense: dense,
    prefixIcon: prefixIcon,
    suffixIcon: suffixIcon,
    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: dense ? 10 : 12),
    border: border(kThinkField),
    enabledBorder: border(kThinkField),
    focusedBorder: border(kThinkAccent),
  );
}

ButtonStyle thinkPrimaryButton({Color color = kThinkAccent}) => ElevatedButton.styleFrom(
      backgroundColor: color,
      foregroundColor: Colors.white,
      disabledBackgroundColor: kThinkField,
      disabledForegroundColor: kThinkHint,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    );

ButtonStyle thinkOutlineButton() => OutlinedButton.styleFrom(
      foregroundColor: kThinkText,
      side: const BorderSide(color: kThinkBorder),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    );

ShapeBorder get thinkDialogShape => RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: const BorderSide(color: kThinkBorder),
    );

void showThinkSnack(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: error ? kThinkError : kThinkSuccess,
    ),
  );
}

Future<bool> confirmThink(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = '확인',
  bool destructive = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      title: Text(title, style: const TextStyle(color: kThinkText, fontWeight: FontWeight.w800)),
      content: Text(message, style: const TextStyle(color: kThinkSub, height: 1.5)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('취소', style: TextStyle(color: kThinkSub)),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: thinkPrimaryButton(color: destructive ? kThinkError : kThinkAccent),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return ok == true;
}

Future<String?> promptThinkText(
  BuildContext context, {
  required String title,
  String initial = '',
  String hint = '',
  String confirmLabel = '저장',
}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      title: Text(title, style: const TextStyle(color: kThinkText, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: kThinkText),
          decoration: thinkInputDecoration(hint: hint),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('취소', style: TextStyle(color: kThinkSub)),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          style: thinkPrimaryButton(),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  controller.dispose();
  return result;
}

String formatUsd(double? v, {int digits = 4}) {
  if (v == null) return '-';
  if (v == 0) return r'$0';
  if (v >= 100) return '\$${v.toStringAsFixed(0)}';
  if (v >= 1) return '\$${v.toStringAsFixed(2)}';
  return '\$${v.toStringAsFixed(digits)}';
}

String formatTokens(int v) {
  if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
  if (v >= 10000) return '${(v / 1000).toStringAsFixed(0)}K';
  if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}K';
  return '$v';
}

String formatRelative(DateTime? t) {
  if (t == null) return '';
  final now = DateTime.now();
  final diff = now.difference(t);
  if (diff.inMinutes < 1) return '방금';
  if (diff.inHours < 1) return '${diff.inMinutes}분 전';
  if (diff.inDays < 1 && now.day == t.day) return '${diff.inHours}시간 전';
  if (diff.inDays < 7) return '${diff.inDays == 0 ? 1 : diff.inDays}일 전';
  final sameYear = now.year == t.year;
  final md = '${t.month}월 ${t.day}일';
  return sameYear ? md : '${t.year}년 $md';
}

String formatDateTime(DateTime? t) {
  if (t == null) return '-';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}
