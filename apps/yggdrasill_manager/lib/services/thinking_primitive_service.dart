import 'package:supabase_flutter/supabase_flutter.dart';

class ThinkingPrimitiveItem {
  const ThinkingPrimitiveItem({
    required this.id,
    required this.code,
    required this.kind,
    required this.category,
    required this.title,
    required this.criteria,
    required this.triggerCond,
    required this.actionSteps,
    required this.trapNote,
    required this.exampleExpr,
    required this.unitScore,
    required this.sortOrder,
    required this.isActive,
  });

  factory ThinkingPrimitiveItem.fromJson(Map<String, dynamic> m) => ThinkingPrimitiveItem(
        id: '${m['id'] ?? ''}',
        code: '${m['code'] ?? ''}',
        kind: '${m['kind'] ?? 'frame'}',
        category: '${m['category'] ?? ''}',
        title: '${m['title'] ?? ''}',
        criteria: '${m['criteria'] ?? ''}',
        triggerCond: '${m['trigger_cond'] ?? ''}',
        actionSteps: '${m['action_steps'] ?? ''}',
        trapNote: '${m['trap_note'] ?? ''}',
        exampleExpr: '${m['example_expr'] ?? ''}',
        unitScore: (m['unit_score'] as num?)?.toDouble() ?? 4.0,
        sortOrder: (m['sort_order'] as num?)?.toInt() ?? 0,
        isActive: m['is_active'] != false,
      );

  final String id;
  final String code;

  /// 'frame'(범용 사고틀, B안) 또는 'algorithm'(실전 알고리즘, A안)
  final String kind;
  final String category;
  final String title;
  final String criteria;
  final String triggerCond;
  final String actionSteps;
  final String trapNote;
  final String exampleExpr;
  final double unitScore;
  final int sortOrder;
  final bool isActive;

  bool get isFrame => kind == 'frame';
  bool get isAlgorithm => kind == 'algorithm';
}

class ThinkingPrimitiveService {
  ThinkingPrimitiveService({SupabaseClient? client}) : _db = client ?? Supabase.instance.client;

  final SupabaseClient _db;

  Future<List<ThinkingPrimitiveItem>> fetchAll() async {
    final res = await _db.rpc('thinking_overview');
    final map = res is Map ? Map<String, dynamic>.from(res) : const <String, dynamic>{};
    return [
      for (final r in (map['items'] as List?) ?? const [])
        if (r is Map) ThinkingPrimitiveItem.fromJson(Map<String, dynamic>.from(r)),
    ];
  }

  Future<void> save({
    String? id,
    required String code,
    required String kind,
    required String category,
    required String title,
    required String criteria,
    required String triggerCond,
    required String actionSteps,
    required String trapNote,
    required String exampleExpr,
    required double unitScore,
    required int sortOrder,
    required bool isActive,
  }) async {
    await _db.rpc('thinking_primitive_save', params: {
      'p_id': id,
      'p_code': code,
      'p_kind': kind,
      'p_category': category,
      'p_title': title,
      'p_criteria': criteria,
      'p_trigger_cond': triggerCond,
      'p_action_steps': actionSteps,
      'p_trap_note': trapNote,
      'p_example_expr': exampleExpr,
      'p_unit_score': unitScore,
      'p_sort_order': sortOrder,
      'p_is_active': isActive,
    });
  }

  Future<void> delete(String id) async {
    await _db.rpc('thinking_primitive_delete', params: {'p_id': id});
  }
}
