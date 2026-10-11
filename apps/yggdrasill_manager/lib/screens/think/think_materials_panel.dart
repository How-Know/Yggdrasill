import 'package:flutter/material.dart';

import '../../services/think/think_controller.dart';
import '../../services/think/think_models.dart';
import 'think_avatars.dart';
import 'think_style.dart';

class ThinkLinkedItem {
  const ThinkLinkedItem({required this.id, required this.title, this.note});

  final String id;
  final String title;
  final String? note;
}

/// 맥락 패널의 자료 영역(컨트롤러 연결). 역할 기능이 준비되지 않으면 그리지 않는다.
class ThinkMaterialsPanel extends StatelessWidget {
  const ThinkMaterialsPanel({super.key});

  ThinkController get _c => ThinkController.instance;

  Future<void> _run(BuildContext context, Future<String?> Function() action) async {
    final error = await action();
    if (error != null && context.mounted) showThinkSnack(context, error, error: true);
  }

  Future<void> _pick(BuildContext context, {required String title, required List<ThinkLinkedItem> options, required Future<String?> Function(String id) onPick}) async {
    final id = await showDialog<String>(
      context: context,
      builder: (_) => _MaterialPickerDialog(title: title, options: options),
    );
    if (id != null && context.mounted) await _run(context, () => onPick(id));
  }

  @override
  Widget build(BuildContext context) {
    if (!_c.rolesReady) return const SizedBox.shrink();
    final selectedId = _c.selectedAssistantMessageId;
    ThinkMessage? selected;
    if (selectedId != null) {
      for (final m in _c.messages) {
        if (m.id == selectedId) selected = m;
      }
    }
    final linkedMemories = [
      for (final id in _c.linkedMemoryIds)
        ThinkLinkedItem(id: id, title: _c.memoryById(id)?.title ?? '(목록에 없는 기억)', note: _c.memoryById(id)?.scopeLabel),
    ];
    final docsById = {for (final n in _c.treeNodes) if (n.kind == ThinkTreeKind.document) n.id: n};
    final linkedDocuments = [
      for (final id in _c.linkedDocumentNodeIds)
        ThinkLinkedItem(id: id, title: docsById[id]?.title ?? '(목록에 없는 문서)', note: _c.conversationById(docsById[id]?.conversationId)?.title),
    ];
    final memoryOptions = [
      for (final m in _c.memories)
        if (m.status == ThinkMemoryStatus.active && !_c.linkedMemoryIds.contains(m.id))
          ThinkLinkedItem(id: m.id, title: m.title, note: '${m.kind.label} · ${m.scopeLabel}'),
    ];
    final documentOptions = [
      for (final n in docsById.values)
        if (!_c.linkedDocumentNodeIds.contains(n.id))
          ThinkLinkedItem(id: n.id, title: n.title, note: _c.conversationById(n.conversationId)?.title),
    ];
    return ThinkMaterialsPanelView(
      hasSelection: selected != null,
      snapshot: _c.selectedMessageSnapshot,
      recordMissing: selected != null && _c.roleRecordMissing(selected),
      showLinks: _c.selectedId != null,
      lockReason: _c.roleLockReason,
      linkedMemories: linkedMemories,
      linkedDocuments: linkedDocuments,
      onLinkMemory: () => _pick(context, title: '이 대화에 기억 연결', options: memoryOptions, onPick: _c.linkMemoryToConversation),
      onLinkDocument: () => _pick(context, title: '이 대화에 종합 문서 연결', options: documentOptions, onPick: _c.linkDocumentToConversation),
      onUnlinkMemory: (id) => _run(context, () => _c.unlinkMemoryFromConversation(id)),
      onUnlinkDocument: (id) => _run(context, () => _c.unlinkDocumentFromConversation(id)),
    );
  }
}

/// 선택한 답변에 실제로 전달된 자료와, 이 대화에 연결한 자료(데이터만 받는다. Preview에서도 쓴다).
class ThinkMaterialsPanelView extends StatelessWidget {
  const ThinkMaterialsPanelView({
    super.key,
    required this.hasSelection,
    required this.snapshot,
    required this.recordMissing,
    this.showLinks = true,
    this.lockReason,
    this.linkedMemories = const [],
    this.linkedDocuments = const [],
    this.onLinkMemory,
    this.onLinkDocument,
    this.onUnlinkMemory,
    this.onUnlinkDocument,
  });

  final bool hasSelection;
  final ThinkMessageContextSnapshot? snapshot;
  final bool recordMissing;
  final bool showLinks;
  final String? lockReason;
  final List<ThinkLinkedItem> linkedMemories;
  final List<ThinkLinkedItem> linkedDocuments;
  final VoidCallback? onLinkMemory;
  final VoidCallback? onLinkDocument;
  final ValueChanged<String>? onUnlinkMemory;
  final ValueChanged<String>? onUnlinkDocument;

  static const _title = TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w800);
  static const _hint = TextStyle(color: kThinkSub, fontSize: 12, height: 1.5);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(header: true, child: const Text('선택한 답변에 쓴 자료', style: _title)),
        const SizedBox(height: 8),
        Semantics(liveRegion: true, container: true, child: _selection()),
        if (showLinks) ...[
          const SizedBox(height: 16),
          Semantics(header: true, child: const Text('이 대화에 연결한 자료', style: _title)),
          const SizedBox(height: 4),
          const Text(
            '연결한 기억은 역할과 관계없이 이 대화에서 씁니다. 종합 문서는 연결했을 때만 본문 앞부분을 Think에 보냅니다.',
            style: _hint,
          ),
          const SizedBox(height: 8),
          ..._linked(linkedMemories, '기억', onUnlinkMemory),
          ..._linked(linkedDocuments, '문서', onUnlinkDocument),
          if (linkedMemories.isEmpty && linkedDocuments.isEmpty) const Text('연결한 자료 없음', style: TextStyle(color: kThinkHint, fontSize: 12)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: lockReason == null ? onLinkMemory : null,
                style: thinkOutlineButton(),
                icon: const Icon(Icons.add_link, size: 16),
                label: const Text('기억 연결'),
              ),
              OutlinedButton.icon(
                onPressed: lockReason == null ? onLinkDocument : null,
                style: thinkOutlineButton(),
                icon: const Icon(Icons.description_outlined, size: 16),
                label: const Text('문서 연결'),
              ),
            ],
          ),
          if (lockReason != null) ...[
            const SizedBox(height: 4),
            Text(lockReason!, style: const TextStyle(color: kThinkHint, fontSize: 12)),
          ],
        ],
      ],
    );
  }

  Widget _selection() {
    final snap = snapshot;
    if (!hasSelection) {
      return const Text('답변의 "자료" 버튼을 누르면 그 답변에 실제로 전달·조회된 자료만 보여 줍니다.', style: _hint);
    }
    if (recordMissing) {
      return const Row(
        children: [
          ThinkBadge('기록 없음'),
          SizedBox(width: 8),
          Expanded(child: Text('역할 기능 전 답변이라 쓴 자료를 기록하지 않았습니다.', style: _hint)),
        ],
      );
    }
    if (snap == null) return const Text('불러오는 중…', style: _hint);
    final memories = snap.materials.where((m) => !m.isDocument).toList();
    final documents = snap.materials.where((m) => m.isDocument).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            ThinkRoleAvatar(role: snap.thinkRoleId, size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Think(${snap.thinkRoleId.label}) 답변 · 기억 ${memories.length}개 · 문서 ${documents.length}개',
                style: const TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (snap.materials.isEmpty) const Text('전달한 자료 없음', style: TextStyle(color: kThinkHint, fontSize: 12)),
        for (final m in snap.materials)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ThinkBadge(m.isDocument ? '문서' : '기억', color: m.isDocument ? kThinkLink : kThinkAccent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    m.title?.isNotEmpty == true ? m.title! : m.id,
                    style: const TextStyle(color: kThinkText, fontSize: 12, height: 1.5),
                  ),
                ),
                if (m.truncated) const Text('앞부분만', style: TextStyle(color: kThinkHint, fontSize: 12)),
              ],
            ),
          ),
      ],
    );
  }

  List<Widget> _linked(List<ThinkLinkedItem> items, String kind, ValueChanged<String>? onUnlink) => [
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                ThinkBadge(kind, color: kind == '문서' ? kThinkLink : kThinkAccent),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kThinkText, fontSize: 12)),
                      if (item.note != null && item.note!.isNotEmpty)
                        Text(item.note!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kThinkHint, fontSize: 12)),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '${item.title} 연결 끊기',
                  onPressed: lockReason == null && onUnlink != null ? () => onUnlink(item.id) : null,
                  icon: const Icon(Icons.link_off, size: 16, color: kThinkSub),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
      ];
}

class _MaterialPickerDialog extends StatefulWidget {
  const _MaterialPickerDialog({required this.title, required this.options});

  final String title;
  final List<ThinkLinkedItem> options;

  @override
  State<_MaterialPickerDialog> createState() => _MaterialPickerDialogState();
}

class _MaterialPickerDialogState extends State<_MaterialPickerDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final shown = q.isEmpty
        ? widget.options
        : widget.options.where((o) => '${o.title} ${o.note ?? ''}'.toLowerCase().contains(q)).toList();
    return AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      title: Text(widget.title, style: const TextStyle(color: kThinkText, fontSize: 18, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 520,
        height: 440,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              style: const TextStyle(color: kThinkText, fontSize: 14),
              decoration: thinkInputDecoration(hint: '제목으로 찾기', prefixIcon: const Icon(Icons.search, color: kThinkSub, size: 18)),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: shown.isEmpty
                  ? const Center(child: Text('연결할 수 있는 자료가 없습니다.', style: TextStyle(color: kThinkHint, fontSize: 13)))
                  : ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (context, i) {
                        final o = shown[i];
                        return ListTile(
                          dense: true,
                          title: Text(o.title, style: const TextStyle(color: kThinkText, fontSize: 14)),
                          subtitle: o.note == null ? null : Text(o.note!, style: const TextStyle(color: kThinkHint, fontSize: 12)),
                          onTap: () => Navigator.pop(context, o.id),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('닫기', style: TextStyle(color: kThinkSub))),
      ],
    );
  }
}
