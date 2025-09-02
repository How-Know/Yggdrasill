import 'package:flutter/material.dart';

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
  }

  void appendEvent(String setId, TagEvent event) {
    final list = _eventsBySetId.putIfAbsent(setId, () => <TagEvent>[]);
    list.add(event);
  }
}


