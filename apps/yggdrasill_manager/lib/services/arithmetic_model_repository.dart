import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ygg_arithmetic/ygg_arithmetic.dart';

class ModelEventRow {
  const ModelEventRow({required this.summary, required this.createdAt, required this.kind});

  final String kind;
  final String summary;
  final DateTime createdAt;

  factory ModelEventRow.fromJson(Map<String, dynamic> json) {
    return ModelEventRow(
      kind: '${json['kind'] ?? ''}',
      summary: '${json['summary'] ?? ''}',
      createdAt: DateTime.tryParse('${json['created_at'] ?? ''}')?.toLocal() ?? DateTime.now(),
    );
  }
}

class ArithmeticModelSnapshot {
  const ArithmeticModelSnapshot({
    required this.policy,
    required this.events,
    required this.attemptCount,
    required this.seedCount,
  });

  final ModelPolicy? policy;
  final List<ModelEventRow> events;
  final int attemptCount;
  final int seedCount;
}

/// 운영 정책 조회·발행. 연산 비용과 문항 점수는 바꾸지 않는다.
class ArithmeticModelRepository {
  ArithmeticModelRepository({SupabaseClient? client}) : _client = client;

  final SupabaseClient? _client;

  SupabaseClient get _db => _client ?? Supabase.instance.client;

  Future<ArithmeticModelSnapshot> load() async {
    final res = await _db.rpc('arithmetic_model_overview');
    final map = res is Map ? Map<String, dynamic>.from(res) : const <String, dynamic>{};
    final policyRaw = map['policy'];
    ModelPolicy? policy;
    if (policyRaw is Map) {
      final row = Map<String, dynamic>.from(policyRaw);
      final params = row['parameters'];
      policy = ModelPolicy.fromJson(
        params is Map ? Map<String, Object?>.from(params) : const {},
        version: (row['version'] as num?)?.toInt() ?? 1,
      );
    }
    final events = <ModelEventRow>[
      for (final row in (map['events'] as List?) ?? const [])
        if (row is Map) ModelEventRow.fromJson(Map<String, dynamic>.from(row)),
    ];
    return ArithmeticModelSnapshot(
      policy: policy,
      events: events,
      attemptCount: (map['attempt_count'] as num?)?.toInt() ?? 0,
      seedCount: (map['seed_count'] as num?)?.toInt() ?? 0,
    );
  }

  Future<void> publish({
    required ModelPolicy policy,
    required int expectedVersion,
    required String reason,
  }) async {
    final error = policy.validate();
    if (error != null) throw ArgumentError(error);
    final why = reason.trim();
    if (why.isEmpty) throw ArgumentError('변경 사유를 적어 주세요.');
    await _db.rpc('arithmetic_model_publish_policy', params: {
      'p_expected_version': expectedVersion,
      'p_parameters': policy.toJson(),
      'p_reason': why,
    });
  }
}
