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

/// 놓았을 때 할 일. [unfile]이면 대화 노드를 지워 '정리 안 됨(미분류)'으로 돌린다.
/// [department]는 부서 칸을 쓸 때만 채운다. 그 부서와 역할이 다른 대화는 옮기면서 역할도 바뀐다.
class ThinkDropPlan {
  const ThinkDropPlan.move({
    this.nodeId,
    this.conversationId,
    required this.parentId,
    required this.index,
    this.department,
  }) : unfile = false;
  const ThinkDropPlan.unfile({this.nodeId, this.conversationId, this.department})
      : unfile = true,
        parentId = null,
        index = 0;

  final bool unfile;
  final String? nodeId;
  final String? conversationId;
  final String? parentId;

  /// 옮긴 뒤 형제 사이의 자리(0부터, 옮기는 항목 자신은 빼고 센다). 서버 RPC와 같은 기준.
  /// 최상위는 부서 칸과 상관없이 전체 최상위 목록 기준이다.
  final int index;
  final ThinkRoleId? department;
}

class ThinkTreeRow {
  const ThinkTreeRow({required this.node, required this.depth, required this.childCount, required this.expanded});

  final ThinkTreeNode node;
  final int depth;
  final int childCount;
  final bool expanded;
}

/// 노드와 대화 목록으로 만든 읽기 전용 트리. 목록에 없는 대화(보관 등)의 대화 노드는 숨긴다.
/// [departments]면 최상위를 부서 칸(총괄·교육·문제 풀이·개발)으로 나눈다. 최상위 폴더는 자기 부서 칸에,
/// 폴더 밖 대화는 대화 역할의 칸에 보인다. 하위 노드는 최상위 조상을 따른다.
class ThinkTree {
  ThinkTree._(this.byId, this._children, this.conversationsById, this.conversationNodes, this.unfiled, this.departments);

  factory ThinkTree.build(List<ThinkTreeNode> nodes, List<ThinkConversation> conversations, {bool departments = false}) {
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
    return ThinkTree._(byId, children, conversationsById, conversationNodes, unfiled, departments);
  }

  final bool departments;
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

  ThinkRoleId roleOf(String? conversationId) => conversationsById[conversationId]?.thinkRoleId ?? ThinkRoleId.lead;

  ThinkTreeNode rootOf(ThinkTreeNode n) {
    var cur = n;
    var guard = 0;
    while (cur.parentId != null && guard++ < 64) {
      final p = byId[cur.parentId];
      if (p == null) break;
      cur = p;
    }
    return cur;
  }

  /// 노드가 보이는 부서 칸.
  ThinkRoleId sectionOf(ThinkTreeNode n) {
    final root = rootOf(n);
    if (root.isFolder) return root.department ?? ThinkRoleId.lead;
    return roleOf(root.conversationId);
  }

  /// [department] 부서의 미분류 대화.
  List<ThinkConversation> unfiledOf(ThinkRoleId department) =>
      unfiled.where((c) => c.thinkRoleId == department).toList();

  /// 폴더 안에 있는데 대화 역할이 폴더 부서와 다르다(옮긴 뒤 역할을 따로 바꾼 경우 등). 표시만 하고 고치지 않는다.
  bool isMisplaced(ThinkTreeNode n) =>
      departments &&
      n.kind == ThinkTreeKind.conversation &&
      n.parentId != null &&
      sectionOf(n) != roleOf(n.conversationId);

  /// [item]을 [department]로 옮기면 역할이 바뀌는 대화 수. 폴더면 안의 모든 대화를 센다.
  int rolesChangedBy(ThinkDragItem item, ThinkRoleId department) {
    final node = item.node ?? (item.conversationId == null ? null : conversationNodes[item.conversationId]);
    if (node == null) return item.conversationId != null && roleOf(item.conversationId) != department ? 1 : 0;
    var count = 0;
    void walk(ThinkTreeNode n, int depth) {
      if (depth > 64) return;
      if (n.kind == ThinkTreeKind.conversation && conversationsById.containsKey(n.conversationId)) {
        if (roleOf(n.conversationId) != department) count += 1;
      }
      for (final c in allChildren(n.id)) {
        walk(c, depth + 1);
      }
    }

    walk(node, 0);
    return count;
  }

  /// [department] 칸의 최상위 맨 끝 자리. 전체 최상위 목록 기준, 옮기는 노드 자신은 뺀다.
  int _sectionEndIndex(ThinkRoleId department, String? draggedId) {
    final roots = allChildren(null).where((n) => n.id != draggedId).toList();
    final last = roots.lastIndexWhere((n) => sectionOf(n) == department);
    return last < 0 ? roots.length : last + 1;
  }

  /// [department]가 있으면 그 부서 칸의 노드만.
  List<ThinkTreeRow> rows(Set<String> collapsed, {ThinkRoleId? department}) {
    final out = <ThinkTreeRow>[];
    final seen = <String>{};
    void walk(String? parentId, int depth) {
      for (final n in children(parentId)) {
        if (parentId == null && department != null && sectionOf(n) != department) continue;
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

  /// 폴더만 깊이 순서대로. '폴더로 이동' 선택지에 쓴다. [department]가 있으면 그 부서 폴더만.
  List<({ThinkTreeNode folder, int depth})> folders({ThinkRoleId? department}) {
    final out = <({ThinkTreeNode folder, int depth})>[];
    final seen = <String>{};
    void walk(String? parentId, int depth) {
      for (final n in allChildren(parentId)) {
        if (!n.isFolder || !seen.add(n.id)) continue;
        if (parentId == null && department != null && sectionOf(n) != department) continue;
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

  List<ThinkTreeNode> documentsOf(String conversationId) => [
        for (final n in byId.values)
          if (n.kind == ThinkTreeKind.document && n.conversationId == conversationId) n,
      ];

  ThinkTreeNode? _dragged(ThinkDragItem item) =>
      item.node ?? (item.conversationId == null ? null : conversationNodes[item.conversationId]);

  /// 끌고 있는 항목이 지금 속한 부서 칸.
  ThinkRoleId sectionOfItem(ThinkDragItem item) {
    final dragged = _dragged(item);
    return dragged != null ? sectionOf(dragged) : roleOf(item.conversationId);
  }

  /// [target]이 null이면 최상위 맨 끝(부서 칸을 쓰면 [department] 칸의 맨 끝, 없으면 지금 칸)에 놓는다.
  /// 놓을 수 없거나 제자리면 null.
  ThinkDropPlan? planDrop(ThinkDragItem item, ThinkTreeNode? target, ThinkDropPosition position, {ThinkRoleId? department}) {
    final dragged = _dragged(item);
    final String? parentId;
    int? index;
    ThinkRoleId? dept;
    if (target == null) {
      parentId = null;
      if (departments) {
        dept = department ?? sectionOfItem(item);
        index = _sectionEndIndex(dept, dragged?.id);
      }
    } else if (position == ThinkDropPosition.inside || position == ThinkDropPosition.insideStart) {
      if (!target.isFolder) return null;
      parentId = target.id;
      if (position == ThinkDropPosition.insideStart) index = 0;
      if (departments) dept = sectionOf(target);
    } else {
      if (dragged?.id == target.id) return null;
      parentId = target.parentId;
      final siblings = allChildren(parentId).where((n) => n.id != dragged?.id).toList();
      final at = siblings.indexWhere((n) => n.id == target.id);
      if (at < 0) return null;
      index = at + (position == ThinkDropPosition.after ? 1 : 0);
      if (departments) dept = sectionOf(target);
    }
    index ??= allChildren(parentId).where((n) => n.id != dragged?.id).length;

    if (dragged != null && dragged.isFolder && parentId != null && isInside(parentId, dragged.id)) return null;
    // 최상위의 발췌·종합 문서는 출처 대화의 부서 칸에 보이므로 다른 부서 최상위로는 옮길 수 없다.
    if (dept != null &&
        parentId == null &&
        dragged != null &&
        !dragged.isFolder &&
        dragged.kind != ThinkTreeKind.conversation &&
        roleOf(dragged.conversationId) != dept) {
      return null;
    }
    if (dragged != null && dragged.parentId == parentId && (dept == null || sectionOf(dragged) == dept)) {
      final current = allChildren(parentId).indexWhere((n) => n.id == dragged.id);
      if (current == index) return null;
    }
    if (dragged != null) return ThinkDropPlan.move(nodeId: dragged.id, parentId: parentId, index: index, department: dept);
    if (item.conversationId == null) return null;
    return ThinkDropPlan.move(conversationId: item.conversationId, parentId: parentId, index: index, department: dept);
  }

  /// 미분류에 놓기. 부서 칸을 쓰면 [department]의 미분류로(없으면 지금 부서), 역할이 다르면 역할도 바뀐다.
  /// 폴더는 놓을 수 없고, 이미 그 부서 미분류에 있으면 null.
  ThinkDropPlan? planUnfile(ThinkDragItem item, {ThinkRoleId? department}) {
    final n = item.node;
    if (n != null && n.kind != ThinkTreeKind.conversation) return null;
    if (!departments) return n == null ? null : ThinkDropPlan.unfile(nodeId: n.id);
    final convId = n?.conversationId ?? item.conversationId;
    if (convId == null) return null;
    final dept = department ?? roleOf(convId);
    if (n == null && roleOf(convId) == dept) return null;
    return ThinkDropPlan.unfile(nodeId: n?.id, conversationId: convId, department: dept);
  }

  /// '폴더로 이동' 메뉴. [folderId]가 null이면 최상위 맨 끝([department] 칸, 없으면 지금 칸).
  ThinkDropPlan? planMoveInto(ThinkDragItem item, String? folderId, {ThinkRoleId? department}) {
    final folder = folderId == null ? null : byId[folderId];
    if (folderId != null && folder == null) return null;
    return planDrop(item, folder, ThinkDropPosition.inside, department: department);
  }

  /// 이 계획대로 옮기면 역할이 바뀌는 대화 수. 부서 칸을 쓰지 않으면 0.
  int rolesChangedByPlan(ThinkDragItem item, ThinkDropPlan plan) {
    final dept = plan.department;
    if (dept == null) return 0;
    return rolesChangedBy(item, dept);
  }
}
