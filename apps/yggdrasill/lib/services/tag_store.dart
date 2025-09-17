import 'package:flutter/material.dart';
import 'academy_db.dart';

class TagEvent {
  final String tagName;
  final int colorValue;
  final int iconCodePoint;
  final DateTime timestamp;
  final String? note;
  const TagEvent({required this.tagName, required this.colorValue, required this.iconCodePoint, required this.timestamp, this.note});
}

class TagStore {
  TagStore._internal();
  static final TagStore instance = TagStore._internal();

  final Map<String, List<TagEvent>> _eventsBySetId = {};
  final ValueNotifier<bool> isSaving = ValueNotifier<bool>(false);
  final ValueNotifier<bool> reachedEnd = ValueNotifier<bool>(false);

  List<TagEvent> getEventsForSet(String setId) {
    return List<TagEvent>.from(_eventsBySetId[setId] ?? const []);
  }

  void setEventsForSet(String setId, List<TagEvent> events) {
    _eventsBySetId[setId] = List<TagEvent>.from(events);
    // DB 반영
    AcademyDbService.instance.setTagEventsForSet(setId, events.map((e) => {
      'id': '${setId}_${e.timestamp.millisecondsSinceEpoch}_${e.tagName}',
      'tag_name': e.tagName,
      'color_value': e.colorValue,
      'icon_code': e.iconCodePoint,
      'timestamp': e.timestamp.toIso8601String(),
      'note': e.note,
    }).toList());
  }

  void appendEvent(String setId, TagEvent event) {
    final list = _eventsBySetId.putIfAbsent(setId, () => <TagEvent>[]);
    list.add(event);
    AcademyDbService.instance.appendTagEvent({
      'id': '${setId}_${event.timestamp.millisecondsSinceEpoch}_${event.tagName}',
      'set_id': setId,
      'tag_name': event.tagName,
      'color_value': event.colorValue,
      'icon_code': event.iconCodePoint,
      'timestamp': event.timestamp.toIso8601String(),
      'note': event.note,
    });
  }

  Future<void> loadAllFromDb() async {
    final rows = await AcademyDbService.instance.getAllTagEvents();
    _eventsBySetId.clear();
    for (final r in rows) {
      final setId = (r['set_id'] as String?) ?? '';
      if (setId.isEmpty) continue;
      final list = _eventsBySetId.putIfAbsent(setId, () => <TagEvent>[]);
      list.add(TagEvent(
        tagName: (r['tag_name'] as String?) ?? '',
        colorValue: (r['color_value'] as int?) ?? 0xFF1976D2,
        iconCodePoint: (r['icon_code'] as int?) ?? 0,
        timestamp: DateTime.tryParse((r['timestamp'] as String?) ?? '') ?? DateTime.now(),
        note: r['note'] as String?,
      ));
    }
  }
}


