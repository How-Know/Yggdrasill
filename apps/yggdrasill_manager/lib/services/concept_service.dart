import 'package:supabase_flutter/supabase_flutter.dart';

/// Concept 종류.
enum ConceptKind { definition, theorem }

extension ConceptKindX on ConceptKind {
  String get dbValue => switch (this) {
        ConceptKind.definition => 'definition',
        ConceptKind.theorem => 'theorem',
      };

  static ConceptKind fromDb(String value) {
    return value == 'theorem' ? ConceptKind.theorem : ConceptKind.definition;
  }
}

/// 개념 엔터티.
class ConceptItem {
  final String id;
  final ConceptKind kind;
  final String? subType;
  final String name;
  final String content;
  final int? level;
  final String? symbol;
  final String? versionLabel;

  const ConceptItem({
    required this.id,
    required this.kind,
    this.subType,
    required this.name,
    required this.content,
    this.level,
    this.symbol,
    this.versionLabel,
  });

  factory ConceptItem.fromMap(Map<String, dynamic> map) {
    return ConceptItem(
      id: map['id'] as String,
      kind: ConceptKindX.fromDb(map['kind'] as String),
      subType: map['sub_type'] as String?,
      name: map['name'] as String? ?? '',
      content: map['content'] as String? ?? '',
      level: map['level'] as int?,
      symbol: map['symbol'] as String?,
      versionLabel: map['version_label'] as String?,
    );
  }

  ConceptItem copyWith({
    String? id,
    ConceptKind? kind,
    String? subType,
    String? name,
    String? content,
    int? level,
    String? symbol,
    String? versionLabel,
  }) {
    return ConceptItem(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      subType: subType ?? this.subType,
      name: name ?? this.name,
      content: content ?? this.content,
      level: level ?? this.level,
      symbol: symbol ?? this.symbol,
      versionLabel: versionLabel ?? this.versionLabel,
    );
  }
}

class ConceptService {
  ConceptService(this._client);

  final SupabaseClient _client;

  Future<String> createConcept({
    required String mainCategoryId,
    required ConceptKind kind,
    String? subType,
    required String name,
    required String content,
    int level = 1,
    String? symbol,
    String? versionLabel,
  }) async {
    final payload = {
      'main_category_id': mainCategoryId,
      'kind': kind.dbValue,
      'sub_type': subType,
      'name': name,
      'content': content,
      'level': level,
      if (symbol != null) 'symbol': symbol,
      if (versionLabel != null) 'version_label': versionLabel,
    };

    final resp = await _client
        .from('concepts')
        .insert(payload)
        .select('id')
        .single();

    return resp['id'] as String;
  }

  Future<void> updateConcept({
    required String id,
    required ConceptKind kind,
    String? subType,
    required String name,
    required String content,
    int? level,
    String? symbol,
    String? versionLabel,
  }) async {
    final payload = {
      'kind': kind.dbValue,
      'sub_type': subType,
      'name': name,
      'content': content,
      if (level != null) 'level': level,
      if (symbol != null) 'symbol': symbol,
      if (versionLabel != null) 'version_label': versionLabel,
    };

    payload.removeWhere((key, value) => value == null);

    await _client.from('concepts').update(payload).eq('id', id);
  }

  Future<void> deleteConcept(String id) {
    return _client.from('concepts').delete().eq('id', id);
  }

  Future<void> moveConcept({
    required String conceptId,
    required String toCategoryId,
  }) async {
    await _client
        .from('concepts')
        .update({'main_category_id': toCategoryId}).eq('id', conceptId);
  }

  Future<void> reorderConcepts({
    required String categoryId,
    required List<String> orderedConceptIds,
  }) async {
    for (var i = 0; i < orderedConceptIds.length; i++) {
      await _client.from('concepts').update({'sort_order': i}).match({
        'id': orderedConceptIds[i],
        'main_category_id': categoryId,
      });
    }
  }

  Future<List<ConceptItem>> fetchConceptsByCategory(
      List<String> categoryIds) async {
    if (categoryIds.isEmpty) return const [];

    final rows = await _client
        .from('concepts')
        .select()
        .filter(
          'main_category_id',
          'in',
          '(${categoryIds.map((e) => '"$e"').join(',')})',
        )
        .order('sort_order', ascending: true)
        .order('created_at', ascending: true);

    return (rows as List<dynamic>)
        .map((e) => ConceptItem.fromMap(
            Map<String, dynamic>.from(e as Map<dynamic, dynamic>)))
        .toList();
  }
}

