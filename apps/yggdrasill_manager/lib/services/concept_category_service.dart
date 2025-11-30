import 'package:supabase_flutter/supabase_flutter.dart';

import 'concept_service.dart';

class CategoryNode {
  final String id;
  final String name;
  final List<CategoryNode> children;
  final bool isShortcut;
  final List<ConceptItem> concepts;

  const CategoryNode({
    required this.id,
    required this.name,
    this.children = const [],
    this.isShortcut = false,
    this.concepts = const [],
  });

  CategoryNode copyWith({
    String? id,
    String? name,
    List<CategoryNode>? children,
    bool? isShortcut,
    List<ConceptItem>? concepts,
  }) {
    return CategoryNode(
      id: id ?? this.id,
      name: name ?? this.name,
      children: children ?? this.children,
      isShortcut: isShortcut ?? this.isShortcut,
      concepts: concepts ?? this.concepts,
    );
  }
}

class CategoryTreeResult {
  final String rootId;
  final List<CategoryNode> nodes;

  const CategoryTreeResult({required this.rootId, required this.nodes});
}

class ConceptCategoryService {
  ConceptCategoryService(this._client);

  final SupabaseClient _client;

  Future<CategoryTreeResult> fetchDomainTree(String domain) async {
    final rootMap = await _client
        .from('concept_categories')
        .select()
        .eq('name', domain)
        .filter('parent_id', 'is', 'null')
        .maybeSingle();

    if (rootMap == null) {
      throw Exception('도메인($domain)을 찾을 수 없습니다.');
    }

    final rootRow = Map<String, dynamic>.from(rootMap);
    final rootId = rootRow['id'] as String;
    final List<dynamic> categoryRaw = await _client
        .from('concept_categories')
        .select()
        .order('depth', ascending: true)
        .order('sort_order', ascending: true)
        .order('name', ascending: true);
    final categoryRows = categoryRaw
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    final childrenMap = <String?, List<Map<String, dynamic>>>{};
    for (final row in categoryRows) {
      final parentId = row['parent_id'] as String?;
      childrenMap.putIfAbsent(parentId, () => []).add(row);
    }

    final domainCategoryIds = <String>{rootId};
    void collectIds(String parentId) {
      for (final child in childrenMap[parentId] ?? const []) {
        final childId = child['id'] as String;
        if (domainCategoryIds.add(childId)) {
          collectIds(childId);
        }
      }
    }

    collectIds(rootId);
    final List<dynamic> conceptRaw = domainCategoryIds.isEmpty
        ? const []
        : await _client
            .from('concepts')
            .select()
            .filter(
              'main_category_id',
              'in',
              '(${domainCategoryIds.map((e) => '"$e"').join(',')})',
            )
            .order('sort_order', ascending: true)
            .order('created_at', ascending: true);
    final conceptRows = conceptRaw
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    final conceptsByCategory = <String, List<ConceptItem>>{};
    for (final row in conceptRows) {
      final categoryId = row['main_category_id'] as String;
      conceptsByCategory
          .putIfAbsent(categoryId, () => [])
          .add(ConceptItem.fromMap(row));
    }

    CategoryNode buildNode(Map<String, dynamic> row) {
      final id = row['id'] as String;
      final childRows = childrenMap[id] ?? const [];
      return CategoryNode(
        id: id,
        name: row['name'] as String? ?? '',
        children: childRows.map(buildNode).toList(growable: false),
        concepts: conceptsByCategory[id] ?? const [],
        isShortcut: row['code'] == 'SHORTCUT',
      );
    }

    final nodes =
        (childrenMap[rootId] ?? const []).map(buildNode).toList(growable: false);
    return CategoryTreeResult(rootId: rootId, nodes: nodes);
  }

  Future<String> createCategory({
    required String name,
    required String? parentId,
  }) async {
    int depth = 0;
    if (parentId != null) {
      final parentMap = await _client
          .from('concept_categories')
          .select('depth')
          .eq('id', parentId)
          .single();
      final parent = Map<String, dynamic>.from(parentMap);
      depth = (parent['depth'] as int? ?? 0) + 1;
    }

    final inserted = await _client
        .from('concept_categories')
        .insert({
          'name': name,
          'parent_id': parentId,
          'depth': depth,
        })
        .select('id')
        .single();
    return inserted['id'] as String;
  }

  Future<void> renameCategory({
    required String id,
    required String name,
  }) async {
    await _client
        .from('concept_categories')
        .update({'name': name}).eq('id', id);
  }

  Future<void> deleteCategory({required String id}) async {
    await _client.from('concept_categories').delete().eq('id', id);
  }

  Future<void> moveCategory({
    required String id,
    required String? newParentId,
  }) async {
    int depth = 0;
    if (newParentId != null) {
      final parentMap = await _client
          .from('concept_categories')
          .select('depth')
          .eq('id', newParentId)
          .single();
      final parent = Map<String, dynamic>.from(parentMap);
      depth = (parent['depth'] as int? ?? 0) + 1;
    }

    await _client.from('concept_categories').update({
      'parent_id': newParentId,
      'depth': depth,
    }).eq('id', id);
  }
}

