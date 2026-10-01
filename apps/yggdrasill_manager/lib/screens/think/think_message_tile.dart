import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/think/think_api.dart';
import '../../services/think/think_models.dart';
import 'think_markdown.dart';
import 'think_style.dart';

class ThinkMessageTile extends StatelessWidget {
  const ThinkMessageTile({
    super.key,
    required this.message,
    this.highlighted = false,
    this.onToggleExcluded,
    this.onExcerpt,
    this.onCodeRequest,
  });

  final ThinkMessage message;

  /// 트리의 발췌에서 '원문 보기'로 왔을 때 잠깐 강조한다.
  final bool highlighted;

  /// 답변 머리에만 붙는 문답 단위 동작. null이면 버튼을 숨긴다.
  final VoidCallback? onToggleExcluded;
  final VoidCallback? onExcerpt;
  final VoidCallback? onCodeRequest;

  @override
  Widget build(BuildContext context) {
    final body = message.isUser
        ? _UserBubble(message: message)
        : _AssistantBlock(
            message: message,
            onToggleExcluded: onToggleExcluded,
            onExcerpt: onExcerpt,
            onCodeRequest: onCodeRequest,
          );
    return Stack(
      clipBehavior: Clip.none,
      children: [
        AnimatedOpacity(
          duration: const Duration(milliseconds: 160),
          opacity: message.contextExcluded ? 0.5 : 1,
          child: body,
        ),
        Positioned(
          left: -8,
          right: -8,
          top: -8,
          bottom: -8,
          child: IgnorePointer(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 250),
              opacity: highlighted ? 1 : 0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: kThinkAccent.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: kThinkAccent.withValues(alpha: 0.6)),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.message});

  final ThinkMessage message;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: kThinkField,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (message.attachments.isNotEmpty) ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.end,
                  children: [for (final a in message.attachments) ThinkAttachmentChip(attachment: a)],
                ),
                const SizedBox(height: 8),
              ],
              Text(message.content, style: const TextStyle(color: kThinkText, fontSize: 14, height: 1.5)),
            ],
          ),
        ),
      ),
    );
  }
}

class ThinkAttachmentChip extends StatelessWidget {
  const ThinkAttachmentChip({super.key, required this.attachment, this.onRemove});

  final ThinkAttachment attachment;
  final VoidCallback? onRemove;

  Future<void> _open(BuildContext context) async {
    try {
      final url = await ThinkApi.instance.signedAttachmentUrl(attachment.path);
      if (context.mounted) await openThinkLink(context, url);
    } catch (e) {
      if (context.mounted) showThinkSnack(context, '첨부 파일을 열지 못했습니다: $e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: kThinkPanel,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: () => _open(context),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: kThinkBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                attachment.isImage ? Icons.image_outlined : Icons.picture_as_pdf_outlined,
                size: 16,
                color: attachment.isImage ? kThinkLink : kThinkError,
              ),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 200),
                child: Text(
                  attachment.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: kThinkText, fontSize: 12),
                ),
              ),
              if (onRemove != null) ...[
                const SizedBox(width: 4),
                InkWell(
                  onTap: onRemove,
                  borderRadius: BorderRadius.circular(8),
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: Icon(Icons.close, size: 14, color: kThinkSub),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _AssistantBlock extends StatelessWidget {
  const _AssistantBlock({required this.message, this.onToggleExcluded, this.onExcerpt, this.onCodeRequest});

  final ThinkMessage message;
  final VoidCallback? onToggleExcluded;
  final VoidCallback? onExcerpt;
  final VoidCallback? onCodeRequest;

  @override
  Widget build(BuildContext context) {
    final streaming = message.status == ThinkMessageStatus.streaming;
    final running = message.toolCalls.where((t) => t.running).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.auto_awesome, size: 16, color: kThinkAccent),
            const SizedBox(width: 8),
            const Text('Think', style: TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w700)),
            if (message.model != null && message.model!.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text(message.model!, style: const TextStyle(color: kThinkHint, fontSize: 12)),
            ],
            if (message.status == ThinkMessageStatus.stopped) ...[
              const SizedBox(width: 8),
              const ThinkBadge('중단됨'),
            ],
            if (message.status == ThinkMessageStatus.error) ...[
              const SizedBox(width: 8),
              const ThinkBadge('오류', color: kThinkError),
            ],
            if (message.contextExcluded) ...[
              const SizedBox(width: 8),
              const Tooltip(
                message: '이 문답은 기록과 트리에는 남지만 AI가 읽는 대화 기록·결정 초안·스펙에서는 빠집니다.',
                child: ThinkBadge('답변에서 제외됨'),
              ),
            ],
            const Spacer(),
            if (onToggleExcluded != null)
              IconButton(
                tooltip: message.contextExcluded
                    ? '이 문답을 다시 AI 답변에 포함'
                    : '이 문답을 AI 답변에서 제외 (기록·트리에는 남음)',
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                color: message.contextExcluded ? kThinkAccent : kThinkSub,
                icon: Icon(message.contextExcluded ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                onPressed: onToggleExcluded,
              ),
            if (onExcerpt != null)
              IconButton(
                tooltip: '이 문답을 트리에 발췌로 남기기',
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                color: kThinkSub,
                icon: const Icon(Icons.account_tree_outlined),
                onPressed: onExcerpt,
              ),
            if (onCodeRequest != null)
              IconButton(
                tooltip: '코드 조사 요청 (Cursor가 저장소를 읽고 조사·제안만 돌려줌)',
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                color: kThinkSub,
                icon: const Icon(Icons.manage_search),
                onPressed: onCodeRequest,
              ),
            if (!streaming && message.content.trim().isNotEmpty)
              IconButton(
                tooltip: '답변 복사 (마크다운)',
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                color: kThinkSub,
                icon: const Icon(Icons.copy_rounded),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: message.content));
                  if (context.mounted) showThinkSnack(context, '복사했습니다.');
                },
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (message.toolCalls.isNotEmpty) ...[
          _ToolTraces(tools: message.toolCalls),
          const SizedBox(height: 12),
        ],
        if ((message.commentary ?? '').trim().isNotEmpty) ...[
          _Collapsible(title: '진행 메모', child: ThinkMarkdown(message.commentary!, fontSize: 13)),
          const SizedBox(height: 12),
        ],
        if (message.content.trim().isNotEmpty) ThinkMarkdown(message.content),
        if (streaming) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: kThinkAccent),
              ),
              const SizedBox(width: 8),
              Text(
                running.isNotEmpty
                    ? '${running.last.label} 중…'
                    : (message.content.isEmpty ? '생각하는 중…' : '작성 중…'),
                style: const TextStyle(color: kThinkSub, fontSize: 12),
              ),
            ],
          ),
        ],
        if (message.errorText != null) ...[
          const SizedBox(height: 8),
          ThinkNotice(text: message.errorText!, color: kThinkError, icon: Icons.error_outline),
        ],
        if (message.sources.isNotEmpty) ...[
          const SizedBox(height: 12),
          _Sources(sources: message.sources),
        ],
      ],
    );
  }
}

class _ToolTraces extends StatelessWidget {
  const _ToolTraces({required this.tools});

  final List<ThinkToolTrace> tools;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final t in tools)
          Tooltip(
            message: t.detail.isEmpty ? t.label : '${t.label}: ${t.detail}',
            waitDuration: const Duration(milliseconds: 400),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: kThinkBg,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: kThinkBorder),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (t.running)
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.5, color: kThinkSub),
                    )
                  else
                    Icon(
                      t.ok ? Icons.check_circle_outline : Icons.error_outline,
                      size: 14,
                      color: t.ok ? kThinkAccent : kThinkError,
                    ),
                  const SizedBox(width: 4),
                  Text(t.label, style: const TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w600)),
                  if (t.detail.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 220),
                      child: Text(
                        t.detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: kThinkHint, fontSize: 12),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _Collapsible extends StatefulWidget {
  const _Collapsible({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  State<_Collapsible> createState() => _CollapsibleState();
}

class _CollapsibleState extends State<_Collapsible> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: kThinkBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kThinkBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(_open ? Icons.expand_less : Icons.expand_more, size: 16, color: kThinkSub),
                  const SizedBox(width: 4),
                  Text(widget.title, style: const TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: widget.child,
            ),
        ],
      ),
    );
  }
}

class _Sources extends StatelessWidget {
  const _Sources({required this.sources});

  final List<ThinkSource> sources;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('출처', style: TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < sources.length; i++)
              Tooltip(
                message: sources[i].url,
                waitDuration: const Duration(milliseconds: 400),
                child: InkWell(
                  onTap: () => openThinkLink(context, sources[i].url),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: kThinkBorder),
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 260),
                      child: Text(
                        '${i + 1}. ${sources[i].label}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: kThinkLink, fontSize: 12),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
