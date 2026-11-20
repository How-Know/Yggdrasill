import 'package:flutter/material.dart';

// 교재 메뉴의 내신기출·모의고사 목록이 함께 쓰는 색과 작은 위젯.
// 색은 교재 화면(textbook_migration_pane.dart)이 쓰는 값 그대로다.
const Color kExamPanel = Color(0xFF131315);
const Color kExamInner = Color(0xFF181818);
const Color kExamBorder = Color(0xFF2A2A2A);
const Color kExamAccent = Color(0xFF33A373);
const Color kExamTextSub = Color(0xFF9FB3B3);
const Color kExamTextMuted = Color(0xFF8A8A8A);
const Color kExamListText = Color(0xFFD8E0E0);
const Color kExamSelectedRow = Color(0xFF1B2B1B);
const Color kExamGreen = Color(0xFF7CC67C);
const Color kExamWarn = Color(0xFFEAB968);
const Color kExamWarnBg = Color(0xFF2D2419);
const Color kExamBlue = Color(0xFF7AA9E6);
const Color kExamBlueBg = Color(0xFF1B2430);
const Color kExamError = Color(0xFFE68A8A);
const Color kExamNeutralBg = Color(0xFF222222);
const Color kExamNeutralFg = Color(0xFF808080);

/// 목록 한 줄의 검수 상태 표시(배지 글·색, 옆에 붙는 설명, 돌고 있는가)
class ExamReviewStatus {
  const ExamReviewStatus(this.label, this.fg, this.bg, {this.detail = '', this.spinning = false});

  final String label;
  final Color fg;
  final Color bg;
  final String detail;
  final bool spinning;
}

/// 교재 목록 아래 묶음(내신기출·모의고사)의 머리 줄: 접고 펴는 화살표, 이름, 오른쪽 개수(읽는 중이면 돌림 표시).
class ExamReviewGroupHeader extends StatelessWidget {
  const ExamReviewGroupHeader({
    super.key,
    required this.title,
    required this.countText,
    required this.expanded,
    required this.loading,
    required this.onToggle,
  });

  final String title;
  final String countText;
  final bool expanded;
  final bool loading;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 12, 14, 10),
        child: Row(
          children: [
            Icon(expanded ? Icons.expand_more : Icons.chevron_right, size: 16, color: kExamTextSub),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800),
              ),
            ),
            if (loading)
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2, color: kExamAccent),
              )
            else
              Text(countText, style: const TextStyle(color: kExamTextMuted, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

/// 묶음 목록을 읽지 못했을 때: 이유와 "다시 시도"
class ExamReviewListError extends StatelessWidget {
  const ExamReviewListError({super.key, required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('목록을 읽지 못했습니다: $message', style: const TextStyle(color: kExamError, fontSize: 12)),
          const SizedBox(height: 4),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 24),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('다시 시도', style: TextStyle(color: kExamError, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

/// 묶음 아래의 한 줄(학교·학년): 이름, 돌고 있으면 돌림 표시, 오른쪽에 확정/전체 수.
class ExamReviewListRow extends StatelessWidget {
  const ExamReviewListRow({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.running,
    required this.countText,
    required this.countTooltip,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool running;
  final String countText;
  final String countTooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 8, 14, 8),
        color: selected ? kExamSelectedRow : Colors.transparent,
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : icon,
              size: 16,
              color: selected ? kExamGreen : kExamTextSub,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? Colors.white : kExamListText,
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                ),
              ),
            ),
            if (running) ...[
              const SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(strokeWidth: 2, color: kExamAccent),
              ),
              const SizedBox(width: 8),
            ],
            Tooltip(
              message: countTooltip,
              child: Text(countText, style: const TextStyle(color: kExamTextMuted, fontSize: 11)),
            ),
          ],
        ),
      ),
    );
  }
}

/// 상태 배지와 그 옆 설명(돌고 있으면 앞에 돌림 표시). 설명은 두 줄까지 보이고 전체는 툴팁으로 본다.
class ExamReviewStatusLine extends StatelessWidget {
  const ExamReviewStatusLine({super.key, required this.status});

  final ExamReviewStatus status;

  @override
  Widget build(BuildContext context) {
    final detail = status.detail.trim();
    return Row(
      children: [
        if (status.spinning) ...[
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2, color: kExamAccent),
          ),
          const SizedBox(width: 8),
        ],
        ExamReviewBadge(label: status.label, fg: status.fg, bg: status.bg),
        if (detail.isNotEmpty) ...[
          const SizedBox(width: 8),
          Flexible(
            child: Tooltip(
              message: detail,
              child: Text(
                detail.split('\n').first,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: kExamTextSub, fontSize: 12, height: 1.35),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class ExamReviewBadge extends StatelessWidget {
  const ExamReviewBadge({super.key, required this.label, required this.fg, required this.bg});

  final String label;
  final Color fg;
  final Color bg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
      child: Text(label, style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w800)),
    );
  }
}

/// 목록 줄 오른쪽의 글자 버튼. [accent] 는 지금 누를 차례인 동작, [danger] 는 중단·삭제.
class ExamReviewRowAction extends StatelessWidget {
  const ExamReviewRowAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.accent = false,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool accent;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final Color fg = onPressed == null
        ? const Color(0xFF4A4A4A)
        : (danger ? kExamError : (accent ? kExamAccent : const Color(0xFFE0E0E0)));
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 14, color: fg),
      label: Text(
        label,
        style: TextStyle(color: fg, fontSize: 12, fontWeight: accent ? FontWeight.w800 : FontWeight.w600),
      ),
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 30),
        backgroundColor: accent && onPressed != null ? kExamAccent.withValues(alpha: 0.14) : null,
        shape: accent
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(999),
                side: BorderSide(color: kExamAccent.withValues(alpha: 0.45)),
              )
            : null,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

/// 여러 건을 한꺼번에 대기열에 넣기 전의 확인 창. 확인을 누르면 true.
Future<bool> showExamReviewStartAllDialog(
  BuildContext context, {
  required String message,
  required String confirmLabel,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1B1B1D),
      title: const Text('검수 시작', style: TextStyle(color: Colors.white)),
      content: Text(message, style: const TextStyle(color: kExamListText, fontSize: 13, height: 1.5)),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('취소')),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: FilledButton.styleFrom(backgroundColor: kExamAccent),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return ok == true;
}
