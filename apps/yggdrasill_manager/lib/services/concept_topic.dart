import 'concept_service.dart';

/// 라이브러리 트리에 붙여 보는 개념 유형·주제 묶음. 설계: docs/architecture/concept-library.md §4.1
class ConceptTreeMeta {
  const ConceptTreeMeta({
    this.typeOf = const {},
    this.typeRank = const {},
    this.anchorOf = const {},
    this.anchorsUnavailable = false,
    this.statementCount = const {},
  });

  static const empty = ConceptTreeMeta();

  /// 개념 id → 기본 서술(개념 본문)을 뺀 서술 수. 없거나 읽지 못하면 키가 없다.
  final Map<String, int> statementCount;

  /// 개념 id → 유형 이름(초안 확정 때 붙은 것). 없으면 유형 없음.
  final Map<String, String> typeOf;

  /// 유형 이름 → 순서(concept_types.sort_order 순). 목록에 없으면 맨 뒤.
  final Map<String, int> typeRank;

  /// 개념 id → 바로 앞에 알아야 하는 개념 id. 다른 폴더를 가리키면 트리에서는 쓰지 않는다.
  final Map<String, String> anchorOf;

  /// 묶음 표를 읽지 못했다(반영 전 등). 유형 순서로만 늘어놓는다.
  final bool anchorsUnavailable;

  List<String> get typeOrder =>
      (typeRank.entries.toList()..sort((a, b) => a.value.compareTo(b.value))).map((e) => e.key).toList();

  int rankOf(String conceptId) {
    final t = typeOf[conceptId];
    if (t == null) return 1 << 20;
    return typeRank[t] ?? (1 << 19);
  }

  ConceptTreeMeta withAnchors(Map<String, String?> changes) {
    final next = Map<String, String>.from(anchorOf);
    changes.forEach((id, anchor) => anchor == null ? next.remove(id) : next[id] = anchor);
    return ConceptTreeMeta(
      typeOf: typeOf,
      typeRank: typeRank,
      anchorOf: next,
      anchorsUnavailable: anchorsUnavailable,
      statementCount: statementCount,
    );
  }
}

class ConceptTopicNode {
  ConceptTopicNode(this.concept, [List<ConceptTopicNode>? children]) : children = children ?? [];

  final ConceptItem concept;
  final List<ConceptTopicNode> children;

  int get size => 1 + children.fold(0, (s, c) => s + c.size);
}

/// 폴더 안 개념 → 주제 묶음 숲. 같은 폴더 안 묶음만 쓰고, 뿌리·형제는 유형 순서 → 저장 순서로 늘어놓는다.
/// 고리(있으면 안 되지만)에 걸린 개념은 뿌리로 둔다.
List<ConceptTopicNode> conceptTopicForest(List<ConceptItem> concepts, ConceptTreeMeta meta) {
  final position = {for (var i = 0; i < concepts.length; i++) concepts[i].id: i};
  final nodes = {for (final c in concepts) c.id: ConceptTopicNode(c)};
  String? parentOf(String id) {
    final a = meta.anchorOf[id];
    return a != null && a != id && nodes.containsKey(a) ? a : null;
  }

  bool reachesItself(String id) {
    var cur = parentOf(id);
    for (var steps = 0; cur != null && steps <= concepts.length; steps++) {
      if (cur == id) return true;
      cur = parentOf(cur);
    }
    return false;
  }

  final roots = <ConceptTopicNode>[];
  for (final c in concepts) {
    final p = parentOf(c.id);
    if (p == null || reachesItself(c.id)) {
      roots.add(nodes[c.id]!);
    } else {
      nodes[p]!.children.add(nodes[c.id]!);
    }
  }
  int compare(ConceptTopicNode a, ConceptTopicNode b) {
    final r = meta.rankOf(a.concept.id).compareTo(meta.rankOf(b.concept.id));
    return r != 0 ? r : position[a.concept.id]!.compareTo(position[b.concept.id]!);
  }

  void sortAll(List<ConceptTopicNode> list) {
    list.sort(compare);
    for (final n in list) {
      sortAll(n.children);
    }
  }

  sortAll(roots);
  return roots;
}

/// 숲을 앞에서부터 펼친 줄(깊이·마지막 형제 여부·조상마다 뒤에 형제가 더 있는지).
class ConceptTopicLine {
  const ConceptTopicLine(this.node, this.depth, this.last, this.ancestorsHaveNext);

  final ConceptTopicNode node;
  final int depth;
  final bool last;
  final List<bool> ancestorsHaveNext;
}

List<ConceptTopicLine> flattenTopicForest(List<ConceptTopicNode> roots) {
  final out = <ConceptTopicLine>[];
  void walk(List<ConceptTopicNode> list, int depth, List<bool> ancestors) {
    for (var i = 0; i < list.length; i++) {
      final last = i == list.length - 1;
      out.add(ConceptTopicLine(list[i], depth, last, ancestors));
      walk(list[i].children, depth + 1, [...ancestors, !last]);
    }
  }

  walk(roots, 0, const []);
  return out;
}

/// [conceptId]를 [anchorId]에 붙이면 고리가 생기는지. [anchors]는 지금 연결.
bool anchorMakesCycle(String conceptId, String? anchorId, Map<String, String> anchors) {
  if (anchorId == null) return false;
  if (anchorId == conceptId) return true;
  var cur = anchorId;
  for (var steps = 0; steps <= anchors.length; steps++) {
    final next = anchors[cur];
    if (next == null) return false;
    if (next == conceptId) return true;
    cur = next;
  }
  return true;
}

/// 연결 전체에 고리가 있는 개념(하나라도 있으면 저장하지 않는다).
List<String> anchorCycleMembers(Map<String, String> anchors) {
  final out = <String>[];
  for (final id in anchors.keys) {
    var cur = anchors[id];
    for (var steps = 0; cur != null && steps <= anchors.length; steps++) {
      if (cur == id) {
        out.add(id);
        break;
      }
      cur = anchors[cur];
    }
  }
  return out;
}

class ConceptAnchorProposalItem {
  const ConceptAnchorProposalItem({
    required this.conceptId,
    required this.anchorId,
    required this.currentAnchorId,
    required this.reason,
  });

  factory ConceptAnchorProposalItem.fromJson(Map<String, dynamic> j) => ConceptAnchorProposalItem(
        conceptId: '${j['concept_id'] ?? ''}',
        anchorId: j['anchor_id'] is String ? j['anchor_id'] as String : null,
        currentAnchorId: j['current_anchor_id'] is String ? j['current_anchor_id'] as String : null,
        reason: '${j['reason'] ?? ''}'.trim(),
      );

  final String conceptId;
  final String? anchorId;
  final String? currentAnchorId;
  final String reason;

  bool get changed => anchorId != currentAnchorId;
}

class ConceptAnchorProposal {
  const ConceptAnchorProposal({
    required this.summary,
    required this.items,
    this.unanswered = const [],
    this.broken = const [],
    this.costUsd,
  });

  factory ConceptAnchorProposal.fromJson(Map<String, dynamic> res) {
    final p = res['proposal'] is Map ? Map<String, dynamic>.from(res['proposal'] as Map) : const <String, dynamic>{};
    final checks = p['checks'] is Map ? Map<String, dynamic>.from(p['checks'] as Map) : const <String, dynamic>{};
    List<String> ids(Object? v) => v is List
        ? [
            for (final x in v)
              if (x is String) x
          ]
        : const [];
    return ConceptAnchorProposal(
      summary: '${p['summary'] ?? ''}'.trim(),
      items: [
        for (final i in (p['items'] is List ? p['items'] as List : const []))
          if (i is Map) ConceptAnchorProposalItem.fromJson(Map<String, dynamic>.from(i)),
      ],
      unanswered: ids(checks['unanswered']),
      broken: ids(checks['broken']),
      costUsd: (res['cost_usd'] as num?)?.toDouble(),
    );
  }

  final String summary;
  final List<ConceptAnchorProposalItem> items;
  final List<String> unanswered;
  final List<String> broken;
  final double? costUsd;
}
