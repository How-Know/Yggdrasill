import 'dart:convert';

class StudentFlow {
  static const List<String> defaultNames = <String>[
    '개념',
    '문제',
    '사고',
    '테스트',
    '서술',
    '행동',
  ];
  static const Map<String, String> legacyNameMap = <String, String>{
    '현행': '개념',
    '선행': '문제',
  };

  final String id;
  final String name;
  final bool enabled;
  final int orderIndex;

  const StudentFlow({
    required this.id,
    required this.name,
    required this.enabled,
    this.orderIndex = 0,
  });

  static String normalizeName(String raw) {
    final trimmed = raw.trim();
    return legacyNameMap[trimmed] ?? trimmed;
  }

  static int defaultPriority(String rawName) {
    final name = normalizeName(rawName);
    final idx = defaultNames.indexOf(name);
    return idx < 0 ? defaultNames.length : idx;
  }

  static bool isDefaultName(String rawName) {
    return defaultNames.contains(normalizeName(rawName));
  }

  StudentFlow copyWith({
    String? id,
    String? name,
    bool? enabled,
    int? orderIndex,
  }) {
    return StudentFlow(
      id: id ?? this.id,
      name: normalizeName(name ?? this.name),
      enabled:
          isDefaultName(name ?? this.name) ? true : (enabled ?? this.enabled),
      orderIndex: orderIndex ?? this.orderIndex,
    );
  }

  factory StudentFlow.fromJson(Map<String, dynamic> json) {
    final normalizedName = normalizeName((json['name'] as String?) ?? '');
    return StudentFlow(
      id: (json['id'] as String?) ?? '',
      name: normalizedName,
      enabled: isDefaultName(normalizedName)
          ? true
          : ((json['enabled'] as bool?) ?? false),
      orderIndex:
          (json['orderIndex'] as int?) ?? (json['order_index'] as int?) ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'enabled': isDefaultName(name) ? true : enabled,
      'orderIndex': orderIndex,
    };
  }

  static List<StudentFlow> decodeList(dynamic raw) {
    if (raw == null) return const <StudentFlow>[];
    dynamic value = raw;
    if (raw is String) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) return const <StudentFlow>[];
      try {
        value = jsonDecode(trimmed);
      } catch (_) {
        return const <StudentFlow>[];
      }
    }
    if (value is List) {
      final List<StudentFlow> flows = [];
      for (final item in value) {
        if (item == null) continue;
        final Map<String, dynamic> map = item is Map<String, dynamic>
            ? item
            : Map<String, dynamic>.from(item as Map);
        final flow = StudentFlow.fromJson(map);
        if (flow.id.isEmpty) continue;
        flows.add(flow);
      }
      return flows;
    }
    return const <StudentFlow>[];
  }

  static List<Map<String, dynamic>> encodeList(List<StudentFlow> flows) {
    return flows.map((f) => f.toJson()).toList();
  }

  static String encodeListToJson(List<StudentFlow> flows) {
    return jsonEncode(encodeList(flows));
  }
}
