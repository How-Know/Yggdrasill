import 'package:flutter/material.dart';

import '../../services/think/think_api.dart';
import '../../services/think/think_controller.dart';
import '../../services/think/think_models.dart';
import '../../services/think/think_tree.dart';
import 'think_style.dart';
import 'think_tree_dialogs.dart';

typedef _DropResolver = ThinkDropPlan? Function(ThinkDragItem item, ThinkDropPosition position);

/// 대화 정리 트리. '정리 안 됨'(트리에 놓지 않은 대화)과 폴더·대화·발췌 트리로 나뉜다.
/// 여기서 하는 정리는 AI 맥락에 영향을 주지 않는다.
class ThinkTreePanel extends StatefulWidget {
  const ThinkTreePanel({super.key, required this.onNewConversation, this.onCollapse});

  final VoidCallback onNewConversation;
  final VoidCallback? onCollapse;

  @override
  State<ThinkTreePanel> createState() => _ThinkTreePanelState();
}

class _ThinkTreePanelState extends State<ThinkTreePanel> {
  String _search = '';
  bool _dragging = false;

  ThinkController get _c => ThinkController.instance;

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) showThinkSnack(context, ThinkApi.treeErrorMessage(e), error: true);
    }
  }

  void _drop(ThinkDropPlan plan) => _run(() => _c.applyDrop(plan));

  // ------------------------------------------------------------ 메뉴 동작
  Future<void> _newFolder({String? parentId}) async {
    final title = await promptThinkText(
      context,
      title: parentId == null ? '새 폴더' : '새 하위 폴더',
      hint: '주제 이름',
      confirmLabel: '만들기',
    );
    if (title == null || title.trim().isEmpty) return;
    await _run(() => _c.createFolder(title, parentId: parentId));
  }

  Future<void> _moveWithPicker(ThinkDragItem item) async {
    final node = item.node ?? _c.tree.conversationNodes[item.conversationId];
    final picked = await showThinkFolderPicker(
      context,
      tree: _c.tree,
      movingFolderId: node != null && node.isFolder ? node.id : null,
      currentParentId: node?.parentId,
    );
    if (picked == null) return;
    final plan = _c.tree.planMoveInto(item, picked == kThinkRootFolder ? null : picked);
    if (plan != null) _drop(plan);
  }

  Future<void> _conversationAction(ThinkConversation conv, ThinkTreeNode? node, String action) async {
    switch (action) {
      case 'rename':
        final title = await promptThinkText(context, title: '대화 이름 바꾸기', initial: conv.title);
        if (title != null) await _run(() => _c.renameConversation(conv.id, title));
      case 'move':
        await _moveWithPicker(node != null ? ThinkDragItem.node(node) : ThinkDragItem.unfiled(conv.id));
      case 'unfile':
        if (node != null) await _run(() => _c.removeNode(node));
      case 'archive':
        await _run(() => _c.setArchived(conv.id, !conv.archived));
      case 'delete':
        final excerpts = _c.tree.excerptsOf(conv.id).length;
        final ok = await confirmThink(
          context,
          title: '대화 삭제',
          message: '"${conv.title}" 대화와 첨부 파일을 지웁니다. 되돌릴 수 없습니다.\n'
              '${excerpts > 0 ? '이 대화에서 만든 발췌 $excerpts개도 함께 지워집니다.\n' : ''}'
              '이 대화에서 확정한 결정은 기억에 그대로 남습니다.',
          confirmLabel: '삭제',
          destructive: true,
        );
        if (ok) await _run(() => _c.deleteConversation(conv.id));
    }
  }

  Future<void> _folderAction(ThinkTreeNode node, String action) async {
    switch (action) {
      case 'subfolder':
        await _newFolder(parentId: node.id);
      case 'rename':
        final title = await promptThinkText(context, title: '폴더 이름 바꾸기', initial: node.title);
        if (title != null) await _run(() => _c.renameNode(node, title));
      case 'move':
        await _moveWithPicker(ThinkDragItem.node(node));
      case 'delete':
        final ok = await confirmThink(
          context,
          title: '폴더 삭제',
          message: '"${node.title}" 폴더를 지웁니다.\n안에 있는 대화·발췌·하위 폴더는 지우지 않고 한 단계 위로 옮깁니다.',
          confirmLabel: '삭제',
          destructive: true,
        );
        if (ok) await _run(() => _c.deleteFolder(node));
    }
  }

  Future<void> _excerptAction(ThinkTreeNode node, String action) async {
    switch (action) {
      case 'open':
        await _c.revealMessages(node.conversationId!, node.sourceMessageIds);
      case 'edit':
        await ThinkExcerptDialog.edit(context, node);
      case 'move':
        await _moveWithPicker(ThinkDragItem.node(node));
      case 'delete':
        final ok = await confirmThink(
          context,
          title: '발췌 삭제',
          message: '"${node.title}" 발췌를 지웁니다. 원본 메시지는 대화에 그대로 남습니다.',
          confirmLabel: '삭제',
          destructive: true,
        );
        if (ok) await _run(() => _c.removeNode(node));
    }
  }

  static PopupMenuItem<String> _item(String value, String label, {bool danger = false}) => PopupMenuItem(
        value: value,
        height: 40,
        child: Text(label, style: TextStyle(color: danger ? kThinkError : kThinkText, fontSize: 13)),
      );

  List<PopupMenuEntry<String>> _conversationMenu(ThinkConversation conv, ThinkTreeNode? node) {
    final streaming = _c.isStreaming && _c.streamingConversationId == conv.id;
    return [
      _item('rename', '이름 바꾸기'),
      if (!conv.archived) _item('move', '폴더로 이동'),
      if (node != null) _item('unfile', '정리 안 됨으로 빼기'),
      _item('archive', conv.archived ? '보관 해제' : '보관'),
      if (!streaming) _item('delete', '삭제', danger: true),
    ];
  }

  List<PopupMenuEntry<String>> _folderMenu() => [
        _item('subfolder', '새 하위 폴더'),
        _item('rename', '이름 바꾸기'),
        _item('move', '폴더로 이동'),
        _item('delete', '삭제', danger: true),
      ];

  List<PopupMenuEntry<String>> _excerptMenu() => [
        _item('open', '원문 보기'),
        _item('edit', '제목·요약 편집'),
        _item('move', '폴더로 이동'),
        _item('delete', '삭제', danger: true),
      ];

  // ------------------------------------------------------------ 행
  Widget _conversationRow(ThinkConversation conv, {ThinkTreeNode? node, int depth = 0, bool draggable = true, String? trailing}) {
    return _TreeRow(
      key: ValueKey('conv-${conv.id}'),
      depth: depth,
      icon: Icons.chat_bubble_outline,
      title: conv.title,
      trailing: trailing ?? formatRelative(conv.sortTime),
      selected: conv.id == _c.selectedId,
      streaming: _c.isStreaming && _c.streamingConversationId == conv.id,
      onTap: () => _c.select(conv.id),
      menuItems: () => _conversationMenu(conv, node),
      onMenu: (a) => _conversationAction(conv, node, a),
      dragItem: !draggable ? null : (node != null ? ThinkDragItem.node(node) : ThinkDragItem.unfiled(conv.id)),
      dragLabel: conv.title,
      onDragChanged: _setDragging,
      resolve: !draggable
          ? null
          : node != null
              ? (item, pos) => _c.tree.planDrop(item, node, pos)
              : (item, _) => _c.tree.planUnfile(item),
      onDrop: _drop,
      unfiledTarget: node == null,
    );
  }

  Widget _nodeRow(ThinkTreeRow row, {bool draggable = true, String? trailing}) {
    final n = row.node;
    final tree = _c.tree;
    switch (n.kind) {
      case ThinkTreeKind.conversation:
        final conv = tree.conversationOf(n);
        if (conv == null) return const SizedBox.shrink();
        return _conversationRow(conv, node: n, depth: row.depth, draggable: draggable, trailing: trailing);
      case ThinkTreeKind.folder:
        final suggested = _c.pendingPlacement?.folderId == n.id;
        return _TreeRow(
          key: ValueKey('node-${n.id}'),
          depth: row.depth,
          icon: row.expanded ? Icons.folder_open_outlined : Icons.folder_outlined,
          iconColor: suggested ? kThinkAccent : kThinkSub,
          title: n.title,
          suggested: suggested,
          tooltip: suggested ? 'Think가 이 대화를 넣자고 제안한 폴더입니다. 대화의 제안 카드에서 승인해야 넣습니다.' : null,
          trailing: suggested ? '제안' : trailing ?? (row.childCount > 0 ? '${row.childCount}' : null),
          expanded: row.expanded,
          hasChildren: row.childCount > 0,
          onToggle: () => _c.toggleFolder(n.id),
          onTap: () => _c.toggleFolder(n.id),
          menuItems: _folderMenu,
          onMenu: (a) => _folderAction(n, a),
          dragItem: draggable ? ThinkDragItem.node(n) : null,
          dragLabel: n.title,
          onDragChanged: _setDragging,
          resolve: draggable ? (item, pos) => tree.planDrop(item, n, pos) : null,
          onDrop: _drop,
          isFolder: true,
        );
      case ThinkTreeKind.excerpt:
        final source = tree.conversationsById[n.conversationId];
        return _TreeRow(
          key: ValueKey('node-${n.id}'),
          depth: row.depth,
          icon: Icons.format_quote_rounded,
          iconColor: kThinkAccent,
          title: n.title,
          trailing: trailing,
          tooltip: [
            if (n.summary != null) n.summary!,
            '출처: ${source?.title ?? '보관했거나 목록에 없는 대화'} · 메시지 ${n.sourceMessageIds.length}개',
          ].join('\n'),
          onTap: () => _c.revealMessages(n.conversationId!, n.sourceMessageIds),
          menuItems: _excerptMenu,
          onMenu: (a) => _excerptAction(n, a),
          dragItem: draggable ? ThinkDragItem.node(n) : null,
          dragLabel: n.title,
          onDragChanged: _setDragging,
          resolve: draggable ? (item, pos) => tree.planDrop(item, n, pos) : null,
          onDrop: _drop,
        );
    }
  }

  void _setDragging(bool v) {
    if (_dragging != v) setState(() => _dragging = v);
  }

  // ------------------------------------------------------------ 목록
  List<Widget> _treeItems() {
    final tree = _c.tree;
    final unfiled = tree.unfiled;
    final rows = tree.rows(_c.collapsedFolders);
    return [
      _SectionHeader(
        label: '정리 안 됨',
        count: unfiled.length,
        collapsed: _c.unfiledCollapsed,
        onToggle: _c.toggleUnfiled,
        tooltip: '아직 폴더에 넣지 않은 대화입니다. 새 대화는 여기에 쌓입니다.',
        resolve: (item) => tree.planUnfile(item),
        onDrop: _drop,
      ),
      if (!_c.unfiledCollapsed) ...[
        for (final conv in unfiled) _conversationRow(conv),
        if (unfiled.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 12, 8),
            child: Text('모두 정리했습니다.', style: TextStyle(color: kThinkHint, fontSize: 12)),
          ),
      ],
      const SizedBox(height: 8),
      _SectionHeader(
        label: '주제',
        tooltip: '폴더를 만들고 대화나 발췌를 끌어다 놓으세요. 여기에 놓으면 최상위 맨 아래로 갑니다.',
        resolve: (item) => tree.planDrop(item, null, ThinkDropPosition.inside),
        onDrop: _drop,
        action: IconButton(
          tooltip: '새 폴더',
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          color: kThinkSub,
          onPressed: _c.forbidden ? null : () => _newFolder(),
          icon: const Icon(Icons.create_new_folder_outlined),
        ),
      ),
      ..._withGhostFolder(rows),
      if (rows.isEmpty && _c.pendingPlacement?.newFolderTitle == null)
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 12, 8),
          child: Text(
            '+ 버튼으로 폴더를 만들고, 대화를 끌어다 놓아 정리하세요.\n대화 답변의 트리 버튼으로 문답을 발췌할 수도 있습니다.',
            style: TextStyle(color: kThinkHint, fontSize: 12, height: 1.5),
          ),
        ),
      if (_dragging && rows.isNotEmpty)
        _RootDropZone(resolve: (item) => tree.planDrop(item, null, ThinkDropPosition.inside), onDrop: _drop),
    ];
  }

  /// 새 폴더 분류 제안이 있으면 만들 자리(상위 폴더의 맨 아래)에 흐린 행을 끼운다. 저장은 승인 뒤에 한다.
  List<Widget> _withGhostFolder(List<ThinkTreeRow> rows) {
    final out = [for (final row in rows) _nodeRow(row)];
    final pending = _c.pendingPlacement;
    final title = pending?.newFolderTitle;
    if (pending == null || title == null) return out;
    var at = rows.length;
    var depth = 0;
    final parentId = pending.newFolderParentId;
    if (parentId != null) {
      final pi = rows.indexWhere((r) => r.node.id == parentId);
      if (pi >= 0) {
        depth = rows[pi].depth + 1;
        at = pi + 1;
        while (at < rows.length && rows[at].depth >= depth) {
          at++;
        }
      }
    }
    out.insert(at, _GhostFolderRow(key: ValueKey('ghost-${pending.id}'), depth: depth, title: title));
    return out;
  }

  List<Widget> _searchItems(String q) {
    final tree = _c.tree;
    bool hit(String? s) => (s ?? '').toLowerCase().contains(q);
    final folders = tree.folders().where((f) => hit(f.folder.title)).toList();
    final excerpts = tree.byId.values
        .where((n) => n.kind == ThinkTreeKind.excerpt && (hit(n.title) || hit(n.summary)))
        .toList();
    final convs = _c.conversations.where((c) => hit(c.title)).toList();
    if (folders.isEmpty && excerpts.isEmpty && convs.isEmpty) {
      return const [
        Padding(
          padding: EdgeInsets.all(16),
          child: Text('찾는 항목이 없습니다.', style: TextStyle(color: kThinkHint, fontSize: 13)),
        ),
      ];
    }
    String where(String? parentId) => parentId == null ? '최상위' : tree.folderPath(parentId);
    ThinkTreeRow flat(ThinkTreeNode n) => ThinkTreeRow(node: n, depth: 0, childCount: 0, expanded: false);
    return [
      for (final f in folders) _nodeRow(flat(f.folder), draggable: false, trailing: where(f.folder.parentId)),
      for (final c in convs)
        _conversationRow(
          c,
          node: tree.conversationNodes[c.id],
          draggable: false,
          trailing: tree.conversationNodes[c.id] == null ? '정리 안 됨' : where(tree.conversationNodes[c.id]!.parentId),
        ),
      for (final e in excerpts) _nodeRow(flat(e), draggable: false, trailing: where(e.parentId)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final q = _search.trim().toLowerCase();
        final loading = (_c.conversationsLoading && _c.conversations.isEmpty) || (_c.treeLoading && _c.treeNodes.isEmpty);
        final error = _c.conversationsError ?? _c.treeError;
        Widget body;
        if (loading) {
          body = const Center(child: CircularProgressIndicator(color: kThinkAccent));
        } else if (error != null && _c.conversations.isEmpty) {
          body = Padding(
            padding: const EdgeInsets.all(12),
            child: Text(error, style: const TextStyle(color: kThinkSub, fontSize: 12)),
          );
        } else if (_c.showArchived) {
          final items = _c.conversations.where((c) => q.isEmpty || c.title.toLowerCase().contains(q)).toList();
          body = items.isEmpty
              ? const Center(child: Text('보관한 대화가 없습니다.', style: TextStyle(color: kThinkHint, fontSize: 13)))
              : ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  children: [for (final c in items) _conversationRow(c, draggable: false)],
                );
        } else {
          body = ListView(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
            children: q.isEmpty ? _treeItems() : _searchItems(q),
          );
        }

        return ThinkPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _c.forbidden ? null : widget.onNewConversation,
                        style: thinkPrimaryButton(),
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('새 대화'),
                      ),
                    ),
                    if (widget.onCollapse != null) ...[
                      const SizedBox(width: 4),
                      IconButton(
                        tooltip: '목록 접기',
                        color: kThinkSub,
                        onPressed: widget.onCollapse,
                        icon: const Icon(Icons.keyboard_double_arrow_left),
                      ),
                    ],
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: TextField(
                  onChanged: (v) => setState(() => _search = v),
                  style: const TextStyle(color: kThinkText, fontSize: 13),
                  decoration: thinkInputDecoration(
                    hint: _c.showArchived ? '보관한 대화 검색' : '대화·폴더·발췌 검색',
                    dense: true,
                    prefixIcon: const Icon(Icons.search, size: 18, color: kThinkHint),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(child: body),
              const Divider(color: kThinkBorder, height: 1),
              const Tooltip(
                message: 'AI는 답변할 때 지금 대화의 기록(답변에서 제외한 문답은 빼고)과 확정한 기억만 참고합니다.\n'
                    '분류를 부탁하면 폴더 이름·경로와 대화 제목만 읽고 제안하며, 발췌 내용은 읽지 않습니다.',
                child: Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 12, 0),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, size: 14, color: kThinkHint),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '트리는 정리용이며 AI 답변 맥락에 쓰이지 않습니다.',
                          style: TextStyle(color: kThinkHint, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    TextButton.icon(
                      onPressed: () => _c.setShowArchived(!_c.showArchived),
                      icon: Icon(_c.showArchived ? Icons.arrow_back : Icons.inventory_2_outlined, size: 16, color: kThinkSub),
                      label: Text(
                        _c.showArchived ? '대화 목록으로' : '보관함',
                        style: const TextStyle(color: kThinkSub, fontSize: 13),
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: '새로고침',
                      iconSize: 18,
                      color: kThinkSub,
                      onPressed: () {
                        _c.refreshConversations();
                        _c.refreshTree();
                      },
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ------------------------------------------------------------------ 위젯
class _SectionHeader extends StatefulWidget {
  const _SectionHeader({
    required this.label,
    required this.resolve,
    required this.onDrop,
    this.count,
    this.collapsed,
    this.onToggle,
    this.tooltip,
    this.action,
  });

  final String label;
  final int? count;
  final bool? collapsed;
  final VoidCallback? onToggle;
  final String? tooltip;
  final Widget? action;
  final ThinkDropPlan? Function(ThinkDragItem item) resolve;
  final ValueChanged<ThinkDropPlan> onDrop;

  @override
  State<_SectionHeader> createState() => _SectionHeaderState();
}

class _SectionHeaderState extends State<_SectionHeader> {
  bool _over = false;

  @override
  Widget build(BuildContext context) {
    final label = Row(
      children: [
        if (widget.collapsed != null)
          Icon(widget.collapsed! ? Icons.chevron_right : Icons.expand_more, size: 16, color: kThinkHint)
        else
          const SizedBox(width: 16),
        const SizedBox(width: 4),
        Text(widget.label, style: const TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
        if (widget.count != null) ...[
          const SizedBox(width: 8),
          Text('${widget.count}', style: const TextStyle(color: kThinkHint, fontSize: 12)),
        ],
      ],
    );
    return DragTarget<ThinkDragItem>(
      onWillAcceptWithDetails: (d) {
        final ok = widget.resolve(d.data) != null;
        if (ok != _over) setState(() => _over = ok);
        return ok;
      },
      onLeave: (_) => setState(() => _over = false),
      onAcceptWithDetails: (d) {
        setState(() => _over = false);
        final plan = widget.resolve(d.data);
        if (plan != null) widget.onDrop(plan);
      },
      builder: (context, _, __) => AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        height: 36,
        decoration: BoxDecoration(
          color: _over ? kThinkAccent.withValues(alpha: 0.16) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _over ? kThinkAccent : Colors.transparent),
        ),
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: widget.onToggle,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: widget.tooltip == null
                        ? label
                        : Tooltip(message: widget.tooltip!, waitDuration: const Duration(milliseconds: 500), child: label),
                  ),
                ),
              ),
            ),
            if (widget.action != null) widget.action!,
          ],
        ),
      ),
    );
  }
}

class _RootDropZone extends StatefulWidget {
  const _RootDropZone({required this.resolve, required this.onDrop});

  final ThinkDropPlan? Function(ThinkDragItem item) resolve;
  final ValueChanged<ThinkDropPlan> onDrop;

  @override
  State<_RootDropZone> createState() => _RootDropZoneState();
}

class _RootDropZoneState extends State<_RootDropZone> {
  bool _over = false;

  @override
  Widget build(BuildContext context) {
    return DragTarget<ThinkDragItem>(
      onWillAcceptWithDetails: (d) {
        final ok = widget.resolve(d.data) != null;
        setState(() => _over = ok);
        return ok;
      },
      onLeave: (_) => setState(() => _over = false),
      onAcceptWithDetails: (d) {
        setState(() => _over = false);
        final plan = widget.resolve(d.data);
        if (plan != null) widget.onDrop(plan);
      },
      builder: (context, _, __) => Container(
        height: 36,
        margin: const EdgeInsets.only(top: 4),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _over ? kThinkAccent.withValues(alpha: 0.16) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _over ? kThinkAccent : kThinkBorder),
        ),
        child: const Text('여기에 놓으면 최상위 맨 아래로', style: TextStyle(color: kThinkHint, fontSize: 12)),
      ),
    );
  }
}

class _TreeRow extends StatefulWidget {
  const _TreeRow({
    super.key,
    required this.depth,
    required this.icon,
    required this.title,
    required this.onTap,
    required this.menuItems,
    required this.onMenu,
    required this.onDrop,
    required this.onDragChanged,
    this.iconColor = kThinkHint,
    this.trailing,
    this.tooltip,
    this.selected = false,
    this.streaming = false,
    this.expanded,
    this.hasChildren = false,
    this.onToggle,
    this.dragItem,
    this.dragLabel = '',
    this.resolve,
    this.isFolder = false,
    this.unfiledTarget = false,
    this.suggested = false,
  });

  /// Think의 대화 분류 제안 대상. 승인 전 표시만 한다.
  final bool suggested;

  final int depth;
  final IconData icon;
  final Color iconColor;
  final String title;
  final String? trailing;
  final String? tooltip;
  final bool selected;
  final bool streaming;
  final bool? expanded;
  final bool hasChildren;
  final VoidCallback? onToggle;
  final VoidCallback onTap;
  final List<PopupMenuEntry<String>> Function() menuItems;
  final ValueChanged<String> onMenu;
  final ThinkDragItem? dragItem;
  final String dragLabel;
  final ValueChanged<bool> onDragChanged;
  final _DropResolver? resolve;
  final ValueChanged<ThinkDropPlan> onDrop;
  final bool isFolder;

  /// '정리 안 됨' 행: 어디에 놓든 '정리 안 됨'으로 돌린다(위치 표시 없이 행 전체 강조).
  final bool unfiledTarget;

  @override
  State<_TreeRow> createState() => _TreeRowState();
}

class _TreeRowState extends State<_TreeRow> {
  ThinkDropPosition? _drop;
  bool _hover = false;

  static const double _height = 36;
  double get _indent => 8 + widget.depth * 16.0;

  ThinkDropPosition _positionAt(Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return ThinkDropPosition.after;
    final ratio = (box.globalToLocal(global).dy / box.size.height).clamp(0.0, 1.0);
    if (!widget.isFolder) return ratio < 0.5 ? ThinkDropPosition.before : ThinkDropPosition.after;
    if (ratio < 0.25) return ThinkDropPosition.before;
    if (ratio > 0.75) {
      return widget.expanded == true && widget.hasChildren ? ThinkDropPosition.insideStart : ThinkDropPosition.after;
    }
    return ThinkDropPosition.inside;
  }

  void _track(ThinkDragItem item, Offset global) {
    final resolve = widget.resolve;
    if (resolve == null) return;
    final pos = _positionAt(global);
    final next = resolve(item, pos) == null ? null : pos;
    if (next != _drop) setState(() => _drop = next);
  }

  Future<void> _openMenuAt(Offset global) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final local = overlay.globalToLocal(global);
    final picked = await showMenu<String>(
      context: context,
      color: kThinkPanel,
      position: RelativeRect.fromLTRB(local.dx, local.dy, overlay.size.width - local.dx, overlay.size.height - local.dy),
      items: widget.menuItems(),
    );
    if (picked != null) widget.onMenu(picked);
  }

  Widget _content() {
    final showMenuButton = _hover || widget.selected;
    Widget title = Text(
      widget.title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: kThinkText,
        fontSize: 13,
        fontWeight: widget.selected ? FontWeight.w700 : FontWeight.w500,
      ),
    );
    if (widget.tooltip != null) {
      title = Tooltip(message: widget.tooltip!, waitDuration: const Duration(milliseconds: 500), child: title);
    }
    return Material(
      color: widget.selected
          ? kThinkAccent.withValues(alpha: 0.16)
          : widget.suggested
              ? kThinkAccent.withValues(alpha: 0.08)
              : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: widget.suggested ? const BorderSide(color: kThinkAccent) : BorderSide.none,
      ),
      child: InkWell(
        onTap: widget.onTap,
        onSecondaryTapDown: (d) => _openMenuAt(d.globalPosition),
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          height: _height,
          child: Row(
            children: [
              SizedBox(width: _indent),
              SizedBox(
                width: 16,
                child: widget.expanded == null || !widget.hasChildren
                    ? null
                    : InkWell(
                        onTap: widget.onToggle,
                        borderRadius: BorderRadius.circular(8),
                        child: Icon(
                          widget.expanded! ? Icons.expand_more : Icons.chevron_right,
                          size: 16,
                          color: kThinkHint,
                        ),
                      ),
              ),
              const SizedBox(width: 4),
              Icon(widget.icon, size: 16, color: widget.iconColor),
              const SizedBox(width: 8),
              Expanded(child: title),
              if (widget.streaming)
                const Padding(
                  padding: EdgeInsets.only(left: 4),
                  child: SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5, color: kThinkAccent),
                  ),
                ),
              if (widget.trailing != null && !showMenuButton)
                Padding(
                  padding: const EdgeInsets.only(left: 8, right: 8),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 96),
                    child: Text(
                      widget.trailing!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: widget.suggested ? kThinkAccent : kThinkHint,
                        fontSize: 12,
                        fontWeight: widget.suggested ? FontWeight.w700 : FontWeight.normal,
                      ),
                    ),
                  ),
                ),
              if (showMenuButton)
                Builder(
                  builder: (btnContext) => IconButton(
                    tooltip: '더보기',
                    visualDensity: VisualDensity.compact,
                    iconSize: 16,
                    color: kThinkSub,
                    icon: const Icon(Icons.more_horiz),
                    onPressed: () {
                      final box = btnContext.findRenderObject() as RenderBox;
                      _openMenuAt(box.localToGlobal(Offset(0, box.size.height)));
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget row = MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: _content(),
    );

    final item = widget.dragItem;
    if (item != null) {
      row = Draggable<ThinkDragItem>(
        data: item,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        onDragStarted: () => widget.onDragChanged(true),
        onDragEnd: (_) => widget.onDragChanged(false),
        onDraggableCanceled: (_, __) => widget.onDragChanged(false),
        feedback: _DragFeedback(icon: widget.icon, label: widget.dragLabel),
        childWhenDragging: Opacity(opacity: 0.4, child: row),
        child: row,
      );
    }

    if (widget.resolve == null) return Padding(padding: const EdgeInsets.symmetric(vertical: 1), child: row);

    return DragTarget<ThinkDragItem>(
      onWillAcceptWithDetails: (d) {
        _track(d.data, d.offset);
        return true;
      },
      onMove: (d) => _track(d.data, d.offset),
      onLeave: (_) => setState(() => _drop = null),
      onAcceptWithDetails: (d) {
        final resolve = widget.resolve!;
        final plan = resolve(d.data, _positionAt(d.offset));
        setState(() => _drop = null);
        if (plan != null) widget.onDrop(plan);
      },
      builder: (context, _, __) {
        final whole = _drop == ThinkDropPosition.inside || (widget.unfiledTarget && _drop != null);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Stack(
            children: [
              row,
              if (whole)
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: kThinkAccent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: kThinkAccent),
                      ),
                    ),
                  ),
                ),
              if (!whole && _drop != null)
                Positioned(
                  left: _indent + (_drop == ThinkDropPosition.insideStart ? 16 : 0),
                  right: 8,
                  top: _drop == ThinkDropPosition.before ? 0 : null,
                  bottom: _drop == ThinkDropPosition.before ? null : 0,
                  child: IgnorePointer(
                    child: Container(
                      height: 2,
                      decoration: BoxDecoration(color: kThinkAccent, borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 아직 만들지 않은 새 폴더 제안. 누를 수도, 끌어 놓을 수도 없다.
class _GhostFolderRow extends StatelessWidget {
  const _GhostFolderRow({super.key, required this.depth, required this.title});

  final int depth;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Think가 새로 만들자고 제안한 폴더입니다. 대화의 제안 카드에서 승인하기 전에는 만들지 않습니다.',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Container(
          height: 36,
          decoration: BoxDecoration(
            color: kThinkAccent.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: kThinkAccent.withValues(alpha: 0.5)),
          ),
          child: Row(
            children: [
              SizedBox(width: 8 + depth * 16.0 + 16 + 4),
              Icon(Icons.create_new_folder_outlined, size: 16, color: kThinkAccent.withValues(alpha: 0.7)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: kThinkSub, fontSize: 13, fontStyle: FontStyle.italic),
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(left: 8, right: 8),
                child: Text('새 폴더 제안', style: TextStyle(color: kThinkAccent, fontSize: 12, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      offset: const Offset(12, 8),
      child: Material(
        color: Colors.transparent,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 240),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: kThinkField,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: kThinkAccent),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: kThinkAccent),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
