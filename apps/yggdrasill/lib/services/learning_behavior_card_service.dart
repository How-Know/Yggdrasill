import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'tenant_service.dart';

class LearningBehaviorCardRecord {
  final String id;
  final String name;
  final int repeatDays;
  final bool isIrregular;
  final List<String> levelContents;
  final int selectedLevelIndex;
  final IconData icon;
  final Color color;
  final int orderIndex;

  const LearningBehaviorCardRecord({
    required this.id,
    required this.name,
    required this.repeatDays,
    required this.isIrregular,
    required this.levelContents,
    required this.selectedLevelIndex,
    required this.icon,
    required this.color,
    required this.orderIndex,
  });

  static int encodeColorValue(Color color) => color.value.toSigned(32);

  static Color decodeColorValue(int value) => Color(value.toUnsigned(32));

  List<String> get safeLevels =>
      levelContents.isEmpty ? const <String>[''] : levelContents;

  int get safeSelectedLevelIndex =>
      selectedLevelIndex.clamp(0, safeLevels.length - 1).toInt();

  Map<String, dynamic> toServerRow({required String academyId}) {
    return {
      'id': id,
      'academy_id': academyId,
      'name': name,
      'repeat_days': repeatDays,
      'is_irregular': isIrregular,
      'level_contents': safeLevels,
      'selected_level_index': safeSelectedLevelIndex,
      'icon_code': icon.codePoint,
      'color': encodeColorValue(color),
      'order_index': orderIndex,
    };
  }

  LearningBehaviorCardRecord copyWith({
    String? name,
    int? repeatDays,
    bool? isIrregular,
    List<String>? levelContents,
    int? selectedLevelIndex,
    int? orderIndex,
    IconData? icon,
    Color? color,
  }) {
    return LearningBehaviorCardRecord(
      id: id,
      name: name ?? this.name,
      repeatDays: repeatDays ?? this.repeatDays,
      isIrregular: isIrregular ?? this.isIrregular,
      levelContents: levelContents ?? this.levelContents,
      selectedLevelIndex: selectedLevelIndex ?? this.selectedLevelIndex,
      icon: icon ?? this.icon,
      color: color ?? this.color,
      orderIndex: orderIndex ?? this.orderIndex,
    );
  }

  static LearningBehaviorCardRecord fromServerRow(Map<String, dynamic> row) {
    int asInt(dynamic value, int fallback) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      return fallback;
    }

    bool asBool(dynamic value, bool fallback) {
      if (value is bool) return value;
      if (value is num) return value != 0;
      if (value is String) {
        final v = value.trim().toLowerCase();
        if (v == 'true' || v == 't' || v == '1') return true;
        if (v == 'false' || v == 'f' || v == '0') return false;
      }
      return fallback;
    }

    final rawLevels = row['level_contents'];
    final parsedLevels = <String>[];
    if (rawLevels is List) {
      for (final item in rawLevels) {
        final text = item?.toString().trim() ?? '';
        if (text.isNotEmpty) parsedLevels.add(text);
      }
    }
    final safeLevels = parsedLevels.isEmpty ? const <String>[''] : parsedLevels;
    final rawSelected = asInt(row['selected_level_index'], 0);
    final selected = rawSelected.clamp(0, safeLevels.length - 1).toInt();
    final iconCode = asInt(row['icon_code'], Icons.directions_run.codePoint);
    final colorValue = asInt(row['color'], 0xFF1E2A36);

    return LearningBehaviorCardRecord(
      id: (row['id'] as String?) ?? '',
      name: ((row['name'] as String?) ?? '').trim(),
      repeatDays: asInt(row['repeat_days'], 1).clamp(1, 9999).toInt(),
      isIrregular: asBool(row['is_irregular'], false),
      levelContents: safeLevels,
      selectedLevelIndex: selected,
      icon: IconData(iconCode, fontFamily: 'MaterialIcons'),
      color: decodeColorValue(colorValue),
      orderIndex: asInt(row['order_index'], 0),
    );
  }
}

class LearningBehaviorCardService {
  LearningBehaviorCardService._();
  static final LearningBehaviorCardService instance =
      LearningBehaviorCardService._();

  Future<List<LearningBehaviorCardRecord>> loadCards() async {
    final academyId = await TenantService.instance.getActiveAcademyId() ??
        await TenantService.instance.ensureActiveAcademy();
    final supa = Supabase.instance.client;

    late final List<dynamic> data;
    try {
      data = await supa
          .from('learning_behavior_cards')
          .select(
              'id,name,repeat_days,is_irregular,level_contents,selected_level_index,icon_code,color,order_index')
          .eq('academy_id', academyId)
          .order('order_index');
    } catch (_) {
      // 구버전 스키마(is_irregular 컬럼 없음) 폴백
      data = await supa
          .from('learning_behavior_cards')
          .select(
              'id,name,repeat_days,level_contents,selected_level_index,icon_code,color,order_index')
          .eq('academy_id', academyId)
          .order('order_index');
    }

    final out = <LearningBehaviorCardRecord>[];
    for (final raw in data) {
      if (raw is Map<String, dynamic>) {
        final item = LearningBehaviorCardRecord.fromServerRow(raw);
        if (item.id.isNotEmpty && item.name.isNotEmpty) {
          out.add(item);
        }
      } else if (raw is Map) {
        final item =
            LearningBehaviorCardRecord.fromServerRow(Map<String, dynamic>.from(raw));
        if (item.id.isNotEmpty && item.name.isNotEmpty) {
          out.add(item);
        }
      }
    }
    out.sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
    return out;
  }

  Future<void> saveAll(List<LearningBehaviorCardRecord> cards) async {
    if (cards.isEmpty) return;
    final academyId = await TenantService.instance.getActiveAcademyId() ??
        await TenantService.instance.ensureActiveAcademy();
    final supa = Supabase.instance.client;

    final rows = cards
        .asMap()
        .entries
        .map((entry) {
          final card = entry.value;
          return card.copyWith(orderIndex: entry.key).toServerRow(
                academyId: academyId,
              );
        })
        .toList();

    try {
      await supa.from('learning_behavior_cards').upsert(rows, onConflict: 'id');
    } catch (_) {
      // 구버전 스키마(is_irregular 컬럼 없음) 폴백
      final legacyRows = rows.map((row) {
        final next = Map<String, dynamic>.from(row);
        next.remove('is_irregular');
        return next;
      }).toList();
      await supa.from('learning_behavior_cards').upsert(legacyRows, onConflict: 'id');
    }
  }
}
