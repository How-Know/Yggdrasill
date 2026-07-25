import 'dart:async';

import 'package:flutter/material.dart';

import '../screens/textbook/textbook_unit_authoring_dialog.dart';
import '../services/textbook_background_extract_controller.dart';

class TextbookBackgroundExtractPanel extends StatelessWidget {
  const TextbookBackgroundExtractPanel({super.key});

  static const _panel = Color(0xFF151A1C);
  static const _border = Color(0xFF2A3739);
  static const _text = Color(0xFFEAF2F2);
  static const _textSub = Color(0xFF9FB3B3);
  static const _accent = Color(0xFF33A373);

  @override
  Widget build(BuildContext context) {
    final controller = TextbookBackgroundExtractController.instance;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final entries = controller.entries;
        if (entries.isEmpty) return const SizedBox.shrink();
        return Positioned(
          right: 18,
          bottom: 18,
          child: SizedBox(
            width: 330,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final entry in entries) ...[
                  _TaskCard(
                    entry: entry,
                    onOpen: () => _restore(context, controller, entry),
                    onDismiss: () => controller.remove(entry.task.key),
                    onRefresh: controller.refresh,
                  ),
                  const SizedBox(height: 8),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  void _restore(
    BuildContext context,
    TextbookBackgroundExtractController controller,
    TextbookBackgroundExtractEntry entry,
  ) {
    controller.remove(entry.task.key);
    unawaited(
      TextbookUnitAuthoringDialog.show(
        context,
        academyId: entry.task.academyId,
        bookId: entry.task.bookId,
        bookName: entry.task.bookName,
        gradeLabel: entry.task.gradeLabel,
        linkId: entry.task.linkId,
      ),
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({
    required this.entry,
    required this.onOpen,
    required this.onDismiss,
    required this.onRefresh,
  });

  final TextbookBackgroundExtractEntry entry;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final progress = entry.progress;
    final ratio = progress.total == 0
        ? 0.0
        : (progress.completed + progress.failed) / progress.total;
    final status = progress.loading
        ? '진행 상태 확인 중...'
        : progress.error.isNotEmpty
            ? '상태 확인 실패'
            : progress.finished
                ? progress.failed > 0
                    ? '완료 · 실패 ${progress.failed}건'
                    : '본문 추출 완료'
                : '문서 ${progress.completed}/${progress.total} 완료'
                    ' · 처리 ${progress.extracting} · 대기 ${progress.queued}';

    return Material(
      color: Colors.transparent,
      elevation: 12,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 11, 8, 12),
          decoration: BoxDecoration(
            color: TextbookBackgroundExtractPanel._panel,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: TextbookBackgroundExtractPanel._border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    progress.finished
                        ? Icons.task_alt
                        : Icons.auto_awesome_motion_outlined,
                    size: 16,
                    color: progress.failed > 0
                        ? const Color(0xFFE68A8A)
                        : TextbookBackgroundExtractPanel._accent,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${entry.task.bookName} · ${entry.task.gradeLabel}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: TextbookBackgroundExtractPanel._text,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '새로고침',
                    visualDensity: VisualDensity.compact,
                    onPressed: onRefresh,
                    icon: const Icon(
                      Icons.refresh,
                      size: 15,
                      color: TextbookBackgroundExtractPanel._textSub,
                    ),
                  ),
                  IconButton(
                    tooltip: '진행 패널 닫기',
                    visualDensity: VisualDensity.compact,
                    onPressed: onDismiss,
                    icon: const Icon(
                      Icons.close,
                      size: 15,
                      color: TextbookBackgroundExtractPanel._textSub,
                    ),
                  ),
                ],
              ),
              Text(
                status,
                style: TextStyle(
                  color: progress.error.isNotEmpty || progress.failed > 0
                      ? const Color(0xFFE68A8A)
                      : TextbookBackgroundExtractPanel._textSub,
                  fontSize: 11.2,
                ),
              ),
              if (progress.questionCount > 0) ...[
                const SizedBox(height: 3),
                Text(
                  '현재 추출 문항 ${progress.questionCount}개',
                  style: const TextStyle(
                    color: TextbookBackgroundExtractPanel._textSub,
                    fontSize: 10.5,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(
                  minHeight: 4,
                  value: progress.loading || progress.total == 0 ? null : ratio,
                  backgroundColor: const Color(0xFF263033),
                  color: progress.failed > 0
                      ? const Color(0xFFE68A8A)
                      : TextbookBackgroundExtractPanel._accent,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                '클릭하면 단원 분석 화면을 다시 엽니다',
                style: TextStyle(
                  color: TextbookBackgroundExtractPanel._textSub,
                  fontSize: 9.8,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
