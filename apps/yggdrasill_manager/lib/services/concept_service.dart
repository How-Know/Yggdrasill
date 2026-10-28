import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

/// concept_attachments 의 키 → 이름. Edge 의 CONCEPT_ATTACHED_LABELS 와 같다.
const Map<String, String> kConceptAttachedLabels = {
  'sources': '출처',
  'statements': '서술',
  'appearances': '등장 위치',
  'placements': '기준 단원 자리',
  'relations': '관계',
  'reviews': '같은 개념 검토',
  'quality_reviews': '범위별 검토 기록',
  'criteria': '정리 기준 연결',
  'anchors': '주제 묶음',
  'content_draft': '수정안',
  'type_link': '유형 연결',
  'content_revisions': '본문 고친 기록',
  'draft_refs': '열린 교재 초안 검토의 대상',
  'shortcuts': '바로가기',
  'operation_prompts': '운영 지시문',
  'other': '기타 연결',
};

/// 붙은 자료를 "출처 2 · 유형 연결 1"처럼 적는다. 0개와 total 은 뺀다.
String conceptAttachedText(Map<String, dynamic> attached) {
  int count(Object? v) => v is num ? v.toInt() : 0;
  return [
    for (final e in kConceptAttachedLabels.entries)
      if (count(attached[e.key]) > 0) '${e.value} ${count(attached[e.key])}',
    for (final e in attached.entries)
      if (e.key != 'total' && !kConceptAttachedLabels.containsKey(e.key) && count(e.value) > 0) '${e.key} ${count(e.value)}',
  ].join(' · ');
}

Map<String, int> _counts(Object? raw) => {
      if (raw is Map)
        for (final e in raw.entries)
          if (e.value is num) '${e.key}': (e.value as num).toInt(),
    };

/// 지우기 전에 본 결과(concept_delete_check). 지울 때 서버가 다시 센다.
class ConceptDeleteCheck {
  const ConceptDeleteCheck({required this.deletable, required this.attached});

  final bool deletable;
  final Map<String, int> attached;

  /// 지울 수 있는지가 분명하지 않으면 예외. 읽지 못한 결과를 "붙은 것 없음"으로 보지 않는다.
  factory ConceptDeleteCheck.fromJson(Object? raw) {
    if (raw is! Map || raw['deletable'] is! bool || raw['attached'] is! Map || (raw['attached'] as Map)['total'] is! num) {
      throw ConceptDeleteException('bad_response', '지울 수 있는지 확인한 결과를 읽지 못했습니다.');
    }
    return ConceptDeleteCheck(deletable: raw['deletable'] as bool, attached: _counts(raw['attached']));
  }
}

class ConceptDeleteException implements Exception {
  ConceptDeleteException(this.code, this.message, {this.attached = const {}});

  final String code;
  final String message;

  /// 거절할 때 서버가 알려 준 붙은 자료(개념) 또는 폴더 안 개념 수({concepts: n}).
  final Map<String, int> attached;

  bool get attachedBlock => code == 'concept_delete_attached';

  static const Map<String, String> _messages = {
    'concept_delete_forbidden': '최고 관리자만 개념을 지울 수 있습니다.',
    'concept_delete_not_found': '개념을 찾지 못했습니다(이미 지워졌을 수 있습니다).',
  };

  static final RegExp _code = RegExp(r'concept_(?:delete_[a-z_]+|folder_not_empty)');

  static ConceptDeleteException from(Object e) {
    if (e is ConceptDeleteException) return e;
    if (e is PostgrestException) {
      final code = e.code ?? '';
      final found = _code.firstMatch(e.message)?.group(0);
      if (found == 'concept_delete_attached') {
        final attached = _counts(_details(e.details));
        final text = conceptAttachedText(attached);
        return ConceptDeleteException(
          'concept_delete_attached',
          text.isEmpty ? '붙은 자료가 있어 지우지 않았습니다.' : '붙은 자료가 있어 지우지 않았습니다: $text',
          attached: attached,
        );
      }
      if (found == 'concept_folder_not_empty') {
        final n = _counts(_details(e.details))['concepts'];
        return ConceptDeleteException(
          'concept_folder_not_empty',
          '이 폴더(하위 폴더 포함)에 개념${n == null ? '이' : ' $n개가'} 있어 지우지 않았습니다. '
              '빈 폴더만 지울 수 있습니다.',
          attached: n == null ? const {} : {'concepts': n},
        );
      }
      if (found != null && _messages.containsKey(found)) return ConceptDeleteException(found, _messages[found]!);
      if (code == 'PGRST202' || code == '42883') {
        return ConceptDeleteException('not_ready', '서버에 개념 지우기 보호가 아직 없어 지우지 않았습니다. DB를 반영한 뒤 다시 해 주세요.');
      }
      if (code == '42501') return ConceptDeleteException('denied', '이 계정으로는 할 수 없는 작업입니다.');
      return ConceptDeleteException(code.isEmpty ? 'error' : code, e.message);
    }
    return ConceptDeleteException('error', e.toString());
  }

  static Object? _details(Object? details) {
    if (details is Map) return details;
    if (details is String) {
      try {
        return jsonDecode(details);
      } on FormatException {
        return null;
      }
    }
    return null;
  }

  @override
  String toString() => message;
}

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

  /// 지우기 전에 붙은 것을 센다. 못 읽으면 ConceptDeleteException(지울 수 있다고 보지 않는다).
  Future<ConceptDeleteCheck> checkDelete(String id) async {
    try {
      return ConceptDeleteCheck.fromJson(await _client.rpc('concept_delete_check', params: {'p_concept_id': id}));
    } catch (e) {
      throw ConceptDeleteException.from(e);
    }
  }

  /// 붙은 것이 하나도 없을 때만 지운다. 서버가 지울 때 다시 세고, 붙은 것이 있으면 ConceptDeleteException.
  Future<void> deleteConcept(String id) async {
    try {
      await _client.rpc('concept_delete', params: {'p_concept_id': id});
    } catch (e) {
      throw ConceptDeleteException.from(e);
    }
  }

  /// 개념 하나를 읽는다(화면에서 열 때). 지웠거나 볼 수 없으면 null.
  Future<ConceptItem?> fetchConcept(String id) async {
    final row = await _client.from('concepts').select().eq('id', id).maybeSingle();
    return row == null ? null : ConceptItem.fromMap(Map<String, dynamic>.from(row));
  }

  /// 이름·종류만 읽는다(화면 표시용, 본문 없음). 지웠거나 볼 수 없으면 null.
  Future<ConceptItem?> fetchConceptHeader(String id) async {
    final row = await _client.from('concepts').select('id,kind,sub_type,name,level').eq('id', id).maybeSingle();
    return row == null ? null : ConceptItem.fromMap(Map<String, dynamic>.from(row));
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

