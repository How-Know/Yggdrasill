import 'package:flutter/material.dart';

import '../screens/design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';
import '../services/textbook_download_progress_service.dart';

/// 마이그레이션 교재 다운로드 진행 안내 — 우하단에 띄우고 칩으로 최소화 가능.
class GlobalTextbookDownloadProgressBanner extends StatelessWidget {
  const GlobalTextbookDownloadProgressBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<TextbookDownloadJob>>(
      valueListenable: TextbookDownloadProgressService.instance.jobsNotifier,
      builder: (context, jobs, _) {
        if (jobs.isEmpty) return const SizedBox.shrink();
        return Positioned(
          right: FabTabBarTokens.fabBarRightInset,
          bottom: FabTabBarTokens.fabMemoFloatingBottomInset,
          child: Material(
            color: Colors.transparent,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final job in jobs)
                  Padding(
                    padding: const EdgeInsets.only(
                      top: FabTabBarTokens.fabMenuItemSpacing,
                    ),
                    child: job.minimized
                        ? _MinimizedChip(job: job)
                        : _ExpandedCard(job: job),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}

class _MinimizedChip extends StatelessWidget {
  const _MinimizedChip({required this.job});

  final TextbookDownloadJob job;

  @override
  Widget build(BuildContext context) {
    final palette = FabTabBarTokens.paletteFor(Theme.of(context).brightness);
    final service = TextbookDownloadProgressService.instance;
    final progress = job.progress;
    final label = switch (job.phase) {
      TextbookDownloadPhase.completed => '완료',
      TextbookDownloadPhase.failed => '실패',
      TextbookDownloadPhase.downloading => progress == null
          ? '다운로드'
          : '${(progress * 100).round()}%',
    };
    final icon = switch (job.phase) {
      TextbookDownloadPhase.completed => Icons.check_circle_outline,
      TextbookDownloadPhase.failed => Icons.error_outline,
      TextbookDownloadPhase.downloading => Icons.download_rounded,
    };

    return Tooltip(
      message: job.title,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () => service.setMinimized(job.id, false),
        child: FabStyleGlassPanel(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: job.phase == TextbookDownloadPhase.downloading &&
                        progress == null
                    ? CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: palette.labelSelected,
                      )
                    : Icon(icon, size: 18, color: palette.labelSelected),
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: FabTabBarTokens.fabMenuLabelStyle(palette).copyWith(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ExpandedCard extends StatelessWidget {
  const _ExpandedCard({required this.job});

  final TextbookDownloadJob job;

  @override
  Widget build(BuildContext context) {
    final palette = FabTabBarTokens.paletteFor(Theme.of(context).brightness);
    final service = TextbookDownloadProgressService.instance;
    final progress = job.progress;
    final subtitle = switch (job.phase) {
      TextbookDownloadPhase.completed => '다운로드가 완료됐어요. 카드를 다시 누르면 열립니다.',
      TextbookDownloadPhase.failed =>
        '다운로드에 실패했어요.${job.error == null || job.error!.isEmpty ? '' : '\n${job.error}'}',
      TextbookDownloadPhase.downloading => job.total > 0
          ? 'PDF 불러오는 중 · ${_formatBytes(job.received)} / ${_formatBytes(job.total)}'
          : 'PDF 불러오는 중...',
    };

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360, minWidth: 280),
      child: FabStyleGlassPanel(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: palette.labelSelected.withOpacity(0.14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    job.phase == TextbookDownloadPhase.completed
                        ? Icons.check_circle_outline
                        : job.phase == TextbookDownloadPhase.failed
                            ? Icons.error_outline
                            : Icons.menu_book_outlined,
                    color: palette.labelSelected,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        job.phase == TextbookDownloadPhase.completed
                            ? '교재 다운로드 완료'
                            : job.phase == TextbookDownloadPhase.failed
                                ? '교재 다운로드 실패'
                                : '교재 다운로드 중',
                        style: FabTabBarTokens.fabMenuLabelStyle(palette)
                            .copyWith(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        job.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.labelUnselected,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                if (job.phase == TextbookDownloadPhase.downloading)
                  InkWell(
                    onTap: () => service.setMinimized(job.id, true),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        Icons.keyboard_arrow_down_rounded,
                        color: palette.labelUnselected,
                        size: 20,
                      ),
                    ),
                  ),
                InkWell(
                  onTap: () => service.dismiss(job.id),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Icons.close,
                      color: palette.labelUnselected,
                      size: 18,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              subtitle,
              style: TextStyle(
                color: palette.labelUnselected,
                fontSize: 12,
                height: 1.35,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (job.phase == TextbookDownloadPhase.downloading) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 4.5,
                  color: palette.labelSelected,
                  backgroundColor: palette.labelUnselected.withOpacity(0.18),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '최초 1회 다운로드 후에는 기기 안에서 바로 열립니다.',
                style: TextStyle(
                  color: palette.labelUnselected.withOpacity(0.85),
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
