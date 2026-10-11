import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/think/think_api.dart';
import '../../services/think/think_models.dart';
import 'think_avatars.dart';
import 'think_markdown.dart';
import 'think_style.dart';

class ThinkMessageTile extends StatelessWidget {
  const ThinkMessageTile({
    super.key,
    required this.message,
    this.roleSnapshot,
    this.roleRecordMissing = false,
    this.materialsSelected = false,
    this.onSelect,
    this.highlighted = false,
    this.onToggleExcluded,
    this.onExcerpt,
    this.onDocument,
    this.onCodeRequest,
    this.onMemoryFeedback,
  });

  final ThinkMessage message;

  /// 이 답변을 만들 때의 역할·전달 자료. 없으면 머리에 역할을 쓰지 않는다.
  final ThinkMessageContextSnapshot? roleSnapshot;

  /// 스냅샷을 확인했는데 없다(역할 기능 전 답변). '기록 없음'으로 표시한다.
  final bool roleRecordMissing;

  /// 맥락 패널이 이 답변의 자료를 보여 주는 중.
  final bool materialsSelected;

  /// 답변의 '자료' 버튼. null이면 숨긴다.
  final VoidCallback? onSelect;

  /// 트리의 발췌에서 '원문 보기'로 왔을 때 잠깐 강조한다.
  final bool highlighted;

  /// 답변 머리에만 붙는 문답 단위 동작. null이면 버튼을 숨긴다.
  final VoidCallback? onToggleExcluded;
  final VoidCallback? onExcerpt;
  final VoidCallback? onDocument;
  final VoidCallback? onCodeRequest;
  final VoidCallback? onMemoryFeedback;

  @override
  Widget build(BuildContext context) {
    final body = message.isUser
        ? _UserBubble(message: message)
        : _AssistantBlock(
            message: message,
            roleSnapshot: roleSnapshot,
            roleRecordMissing: roleRecordMissing,
            materialsSelected: materialsSelected,
            onSelect: onSelect,
            onToggleExcluded: onToggleExcluded,
            onExcerpt: onExcerpt,
            onDocument: onDocument,
            onCodeRequest: onCodeRequest,
            onMemoryFeedback: onMemoryFeedback,
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
    final askedBy = message.askedByLabel;
    final bubble = _bubble();
    if (askedBy == null) return bubble;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Tooltip(
          message: '운영자가 아니라 Cursor가 Think에게 보낸 질문입니다.',
          waitDuration: const Duration(milliseconds: 400),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.smart_toy_outlined, size: 14, color: kThinkLink),
              const SizedBox(width: 4),
              ThinkBadge(askedBy, color: kThinkLink),
            ],
          ),
        ),
        const SizedBox(height: 4),
        bubble,
      ],
    );
  }

  Widget _bubble() {
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
  const _AssistantBlock({
    required this.message,
    this.roleSnapshot,
    this.roleRecordMissing = false,
    this.materialsSelected = false,
    this.onSelect,
    this.onToggleExcluded,
    this.onExcerpt,
    this.onDocument,
    this.onCodeRequest,
    this.onMemoryFeedback,
  });

  final ThinkMessage message;
  final ThinkMessageContextSnapshot? roleSnapshot;
  final bool roleRecordMissing;
  final bool materialsSelected;
  final VoidCallback? onSelect;
  final VoidCallback? onToggleExcluded;
  final VoidCallback? onExcerpt;
  final VoidCallback? onDocument;
  final VoidCallback? onCodeRequest;
  final VoidCallback? onMemoryFeedback;

  @override
  Widget build(BuildContext context) {
    final streaming = message.status == ThinkMessageStatus.streaming;
    final running = message.toolCalls.where((t) => t.running).toList();
    final role = roleSnapshot?.thinkRoleId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (role != null) ThinkRoleAvatar(role: role, size: 22) else const Icon(Icons.auto_awesome, size: 16, color: kThinkAccent),
            const SizedBox(width: 8),
            Text(role != null ? 'Think(${role.label})' : 'Think', style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w700)),
            if (roleRecordMissing) ...[
              const SizedBox(width: 8),
              const Tooltip(
                message: '역할 기능 전 답변이라 어떤 역할로 어떤 자료를 썼는지 기록이 없습니다.',
                child: ThinkBadge('기록 없음'),
              ),
            ],
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
            if (onSelect != null)
              Semantics(
                selected: materialsSelected,
                child: IconButton(
                  tooltip: '이 답변에 쓴 자료 보기',
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  color: materialsSelected ? kThinkAccent : kThinkSub,
                  icon: const Icon(Icons.library_books_outlined),
                  onPressed: onSelect,
                ),
              ),
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
            if (onDocument != null)
              IconButton(
                tooltip: '선택한 출처로 종합 문서를 폴더에 저장',
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                color: kThinkSub,
                icon: const Icon(Icons.description_outlined),
                onPressed: onDocument,
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
            if (onMemoryFeedback != null)
              IconButton(
                tooltip: '피드백으로 기억 초안 요청 (승인 전에는 AI 맥락에 넣지 않음)',
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                color: kThinkSub,
                icon: const Icon(Icons.rate_review_outlined),
                onPressed: onMemoryFeedback,
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
        if (message.relay != null) ...[
          const SizedBox(height: 12),
          _RelayVerdictBox(verdict: message.relay!),
        ],
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
                    : (message.content.isEmpty ? '응답 준비 중…' : '작성 중…'),
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

/// 커서 문의 답변의 판정. 커서는 '사장님 확인 필요' 답을 근거로 진행하지 않는다.
class _RelayVerdictBox extends StatelessWidget {
  const _RelayVerdictBox({required this.verdict});

  final ThinkRelayVerdict verdict;

  @override
  Widget build(BuildContext context) {
    final color = verdict.answered ? kThinkSuccess : kThinkAccent;
    final items = verdict.answered ? verdict.basis : verdict.ownerQuestions;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kThinkBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(verdict.answered ? Icons.verified_outlined : Icons.help_outline, size: 16, color: color),
              const SizedBox(width: 8),
              Text(
                verdict.answered ? '기존 결정 근거' : '사장님 확인 필요',
                style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  verdict.answered ? '승인된 기억을 근거로 답했습니다.' : 'Cursor는 이 답을 근거로 진행하지 않습니다.',
                  style: const TextStyle(color: kThinkHint, fontSize: 12),
                ),
              ),
            ],
          ),
          if (items.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final item in items)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('· $item', style: const TextStyle(color: kThinkSub, fontSize: 13, height: 1.4)),
              ),
          ],
        ],
      ),
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
