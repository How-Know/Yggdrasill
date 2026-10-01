import 'think_models.dart';

/// 끌어서 옮기는 대상: 트리 노드, 또는 아직 트리에 놓지 않은 대화.
class ThinkDragItem {
  const ThinkDragItem.node(ThinkTreeNode this.node) : conversationId = null;
  const ThinkDragItem.unfiled(String this.conversationId) : node = null;

  final ThinkTreeNode? node;
  final String? conversationId;

  bool get isConversation => node == null || node!.kind == ThinkTreeKind.conversation;
}

enum ThinkDropPosition { before, after, inside, insideStart }

/// 놓았을 때 할 일. [unfile]이면 대화 노드를 지워 '정리 안 됨'으로 돌린다.
class ThinkDropPlan {
  const ThinkDropPlan.move({this.nodeId, this.conversationId, required this.parentId, required this.index})
      : unfile = false;
  const ThinkDropPlan.unfile(String this.nodeId)
      : unfile = true,
        conversationId = null,
        parentId = null,
        index = 0;

  final bool unfile;
  final String? nodeId;
  final String? conversationId;
  final String? parentId;

  /// 옮긴 뒤 형제 사이의 자리(0부터, 옮기는 항목 자신은 빼고 센다). 서버 RPC와 같은 기준.
  final int index;
}

class ThinkTreeRow {
  const ThinkTreeRow({required this.node, required this.depth, required this.childCount, required this.expanded});

  final ThinkTreeNode node;
  final int depth;
  final int childCount;
  final bool expanded;
}

/// 노드와 대화 목록으로 만든 읽기 전용 트리. 목록에 없는 대화(보관 등)의 대화 노드는 숨긴다.
class ThinkTree {
  ThinkTree._(this.byId, this._children, this.conversationsById, this.conversationNodes, this.unfiled);

  factory ThinkTree.build(List<ThinkTreeNode> nodes, List<ThinkConversation> conversations) {
    final byId = {for (final n in nodes) n.id: n};
    final children = <String?, List<ThinkTreeNode>>{};
    for (final n in nodes) {
      final parent = n.parentId != null && byId.containsKey(n.parentId) ? n.parentId : null;
      children.putIfAbsent(parent, () => []).add(n);
    }
    for (final list in children.values) {
      list.sort((a, b) {
        final c = a.sortOrder.compareTo(b.sortOrder);
        if (c != 0) return c;
        final t = (a.createdAt ?? DateTime(1970)).compareTo(b.createdAt ?? DateTime(1970));
        return t != 0 ? t : a.id.compareTo(b.id);
      });
    }
    final conversationNodes = {
      for (final n in nodes)
        if (n.kind == ThinkTreeKind.conversation && n.conversationId != null) n.conversationId!: n,
    };
    final conversationsById = {for (final c in conversations) c.id: c};
    final unfiled = conversations.where((c) => !conversationNodes.containsKey(c.id)).toList();
    return ThinkTree._(byId, children, conversationsById, conversationNodes, unfiled);
  }

  final Map<String, ThinkTreeNode> byId;
  final Map<String?, List<ThinkTreeNode>> _children;
  final Map<String, ThinkConversation> conversationsById;
  final Map<String, ThinkTreeNode> conversationNodes;

  /// 트리에 놓지 않은 대화. 대화 목록 순서(최근 순)를 그대로 따른다.
  final List<ThinkConversation> unfiled;

  bool get isEmpty => children(null).isEmpty;

  bool isVisible(ThinkTreeNode n) =>
      n.kind != ThinkTreeKind.conversation || conversationsById.containsKey(n.conversationId);

  /// 숨긴 노드까지 포함한 형제 목록. 서버의 순서 번호는 이 목록 기준이다.
  List<ThinkTreeNode> allChildren(String? parentId) => _children[parentId] ?? const [];

  List<ThinkTreeNode> children(String? parentId) => allChildren(parentId).where(isVisible).toList();

  ThinkConversation? conversationOf(ThinkTreeNode n) => conversationsById[n.conversationId];

  String titleOf(ThinkTreeNode n) =>
      n.kind == ThinkTreeKind.conversation ? (conversationOf(n)?.title ?? '대화') : n.title;

  /// [nodeId]가 [ancestorId] 자신이거나 그 아래에 있으면 true.
  bool isInside(String? nodeId, String ancestorId) {
    var cur = nodeId;
    var guard = 0;
    while (cur != null && guard++ < 64) {
      if (cur == ancestorId) return true;
      cur = byId[cur]?.parentId;
    }
    return false;
  }

  List<ThinkTreeRow> rows(Set<String> collapsed) {
    final out = <ThinkTreeRow>[];
    final seen = <String>{};
    void walk(String? parentId, int depth) {
      for (final n in children(parentId)) {
        if (!seen.add(n.id)) continue;
        final kids = n.isFolder ? children(n.id).length : 0;
        final expanded = n.isFolder && !collapsed.contains(n.id);
        out.add(ThinkTreeRow(node: n, depth: depth, childCount: kids, expanded: expanded));
        if (expanded) walk(n.id, depth + 1);
      }
    }

    walk(null, 0);
    return out;
  }

  /// 폴더만 깊이 순서대로. '폴더로 이동' 선택지에 쓴다.
  List<({ThinkTreeNode folder, int depth})> folders() {
    final out = <({ThinkTreeNode folder, int depth})>[];
    final seen = <String>{};
    void walk(String? parentId, int depth) {
      for (final n in allChildren(parentId)) {
        if (!n.isFolder || !seen.add(n.id)) continue;
        out.add((folder: n, depth: depth));
        walk(n.id, depth + 1);
      }
    }

    walk(null, 0);
    return out;
  }

  String folderPath(String? folderId) {
    final names = <String>[];
    var cur = folderId == null ? null : byId[folderId];
    var guard = 0;
    while (cur != null && guard++ < 64) {
      names.insert(0, cur.title);
      cur = cur.parentId == null ? null : byId[cur.parentId];
    }
    return names.join(' / ');
  }

  List<ThinkTreeNode> excerptsOf(String conversationId) => [
        for (final n in byId.values)
          if (n.kind == ThinkTreeKind.excerpt && n.conversationId == conversationId) n,
      ];

  ThinkTreeNode? _dragged(ThinkDragItem item) =>
      item.node ?? (item.conversationId == null ? null : conversationNodes[item.conversationId]);

  /// [target]이 null이면 최상위 맨 끝에 놓는다. 놓을 수 없거나 제자리면 null.
  ThinkDropPlan? planDrop(ThinkDragItem item, ThinkTreeNode? target, ThinkDropPosition position) {
    final dragged = _dragged(item);
    final String? parentId;
    int? index;
    if (target == null) {
      parentId = null;
    } else if (position == ThinkDropPosition.inside || position == ThinkDropPosition.insideStart) {
      if (!target.isFolder) return null;
      parentId = target.id;
      if (position == ThinkDropPosition.insideStart) index = 0;
    } else {
      if (dragged?.id == target.id) return null;
      parentId = target.parentId;
      final siblings = allChildren(parentId).where((n) => n.id != dragged?.id).toList();
      final at = siblings.indexWhere((n) => n.id == target.id);
      if (at < 0) return null;
      index = at + (position == ThinkDropPosition.after ? 1 : 0);
    }
    index ??= allChildren(parentId).where((n) => n.id != dragged?.id).length;

    if (dragged != null && dragged.isFolder && parentId != null && isInside(parentId, dragged.id)) return null;
    if (dragged != null && dragged.parentId == parentId) {
      final current = allChildren(parentId).indexWhere((n) => n.id == dragged.id);
      if (current == index) return null;
    }
    if (dragged != null) return ThinkDropPlan.move(nodeId: dragged.id, parentId: parentId, index: index);
    if (item.conversationId == null) return null;
    return ThinkDropPlan.move(conversationId: item.conversationId, parentId: parentId, index: index);
  }

  /// '정리 안 됨'에 놓기. 트리에 놓인 대화만 가능하다.
  ThinkDropPlan? planUnfile(ThinkDragItem item) {
    final n = item.node;
    if (n == null || n.kind != ThinkTreeKind.conversation) return null;
    return ThinkDropPlan.unfile(n.id);
  }

  /// '폴더로 이동' 메뉴. [folderId]가 null이면 최상위 맨 끝.
  ThinkDropPlan? planMoveInto(ThinkDragItem item, String? folderId) {
    final folder = folderId == null ? null : byId[folderId];
    if (folderId != null && folder == null) return null;
    return planDrop(item, folder, ThinkDropPosition.inside);
  }
}
