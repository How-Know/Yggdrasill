import 'package:supabase_flutter/supabase_flutter.dart';

class ArithmeticPrimitiveItem {
  const ArithmeticPrimitiveItem({
    required this.id,
    required this.code,
    required this.category,
    required this.title,
    required this.criteria,
    required this.exampleExpr,
    required this.unitScore,
    required this.estSeconds,
    required this.conceptId,
    required this.conceptName,
    required this.conceptContent,
    required this.conceptFolder,
    required this.conceptChanged,
    required this.conceptMissing,
    required this.sortOrder,
    required this.isActive,
  });

  factory ArithmeticPrimitiveItem.fromJson(Map<String, dynamic> m) {
    final folderRaw = m['concept_folder'];
    return ArithmeticPrimitiveItem(
      id: '${m['id'] ?? ''}',
      code: '${m['code'] ?? ''}',
      category: '${m['category'] ?? ''}',
      title: '${m['title'] ?? ''}',
      criteria: '${m['criteria'] ?? ''}',
      exampleExpr: '${m['example_expr'] ?? ''}',
      unitScore: (m['unit_score'] as num?)?.toDouble() ?? 1.0,
      estSeconds: (m['est_seconds'] as num?)?.toDouble() ?? 1.5,
      conceptId: m['concept_id'] is String && '${m['concept_id']}'.isNotEmpty ? '${m['concept_id']}' : null,
      conceptName: m['concept_name'] is String ? '${m['concept_name']}' : null,
      conceptContent: m['concept_content'] is String ? '${m['concept_content']}' : null,
      conceptFolder: folderRaw is List ? [for (final x in folderRaw) '$x'] : const [],
      conceptChanged: m['concept_changed'] == true,
      conceptMissing: m['concept_missing'] == true,
      sortOrder: (m['sort_order'] as num?)?.toInt() ?? 0,
      isActive: m['is_active'] != false,
    );
  }

  final String id;
  final String code;
  final String category;
  final String title;
  final String criteria;
  final String exampleExpr;
  final double unitScore;
  final double estSeconds;
  final String? conceptId;
  final String? conceptName;
  final String? conceptContent;
  final List<String> conceptFolder;
  final bool conceptChanged;
  final bool conceptMissing;
  final int sortOrder;
  final bool isActive;
}

class ArithmeticLibraryConcept {
  const ArithmeticLibraryConcept({
    required this.id,
    required this.name,
    required this.content,
    required this.typeName,
    required this.folder,
    required this.primitiveCount,
  });

  factory ArithmeticLibraryConcept.fromJson(Map<String, dynamic> m) {
    final folderRaw = m['folder'];
    return ArithmeticLibraryConcept(
      id: '${m['id'] ?? ''}',
      name: '${m['name'] ?? ''}',
      content: '${m['content'] ?? ''}',
      typeName: '${m['type_name'] ?? '방법'}',
      folder: folderRaw is List ? [for (final x in folderRaw) '$x'] : const [],
      primitiveCount: (m['primitive_count'] as num?)?.toInt() ?? 0,
    );
  }

  final String id;
  final String name;
  final String content;
  final String typeName;
  final List<String> folder;
  final int primitiveCount;

  bool get isArithmetic => typeName == '연산';
  String get folderPath => folder.join(' › ');
}

class ArithmeticOverviewData {
  const ArithmeticOverviewData({
    required this.primitives,
    required this.concepts,
  });

  final List<ArithmeticPrimitiveItem> primitives;
  final List<ArithmeticLibraryConcept> concepts;
}

class ArithmeticPrimitiveService {
  ArithmeticPrimitiveService({SupabaseClient? client}) : _db = client ?? Supabase.instance.client;

  final SupabaseClient _db;

  Future<ArithmeticOverviewData> fetchOverview() async {
    final res = await _db.rpc('arithmetic_overview');
    final map = res is Map ? Map<String, dynamic>.from(res) : const <String, dynamic>{};
    final prims = [
      for (final r in (map['primitives'] as List?) ?? const [])
        if (r is Map) ArithmeticPrimitiveItem.fromJson(Map<String, dynamic>.from(r)),
    ];
    final concepts = [
      for (final r in (map['concepts'] as List?) ?? const [])
        if (r is Map) ArithmeticLibraryConcept.fromJson(Map<String, dynamic>.from(r)),
    ];
    return ArithmeticOverviewData(primitives: prims, concepts: concepts);
  }

  Future<void> savePrimitive({
    String? id,
    required String code,
    required String category,
    required String title,
    required String criteria,
    required String exampleExpr,
    required double unitScore,
    required double estSeconds,
    required String? conceptId,
    required int sortOrder,
    required bool isActive,
  }) async {
    await _db.rpc('arithmetic_primitive_save', params: {
      'p_id': id,
      'p_code': code,
      'p_category': category,
      'p_title': title,
      'p_criteria': criteria,
      'p_example_expr': exampleExpr,
      'p_unit_score': unitScore,
      'p_est_seconds': estSeconds,
      'p_concept_id': conceptId,
      'p_sort_order': sortOrder,
      'p_is_active': isActive,
    });
  }

  Future<void> deletePrimitive(String id) async {
    await _db.rpc('arithmetic_primitive_delete', params: {'p_id': id});
  }

  Future<void> syncConceptMd5(String id) async {
    await _db.rpc('arithmetic_primitive_sync_concept', params: {'p_id': id});
  }

  Future<void> setConceptKind(String conceptId, String typeName) async {
    await _db.rpc('arithmetic_set_concept_kind', params: {
      'p_concept_id': conceptId,
      'p_type_name': typeName,
    });
  }
}
