import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'academy_db.dart';

class ScheduleEvent {
  final String id;
  final String? groupId; // 드래그 범위 등록 묶음
  final DateTime date; // 날짜 단위 (로컬 날짜)
  final String title;
  final String? note;
  final int? startHour; // 0-23
  final int? startMinute; // 0-59
  final int? endHour; // 0-23
  final int? endMinute; // 0-59
  final int? color; // ARGB 정수
  final List<String> tags;
  final String? iconKey; // 아이콘 키

  ScheduleEvent({
    required this.id,
    this.groupId,
    required this.date,
    required this.title,
    this.note,
    this.startHour,
    this.startMinute,
    this.endHour,
    this.endMinute,
    this.color,
    this.tags = const <String>[],
    this.iconKey,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'groupId': groupId,
        'date': date.toIso8601String(),
        'title': title,
        'note': note,
        'startHour': startHour,
        'startMinute': startMinute,
        'endHour': endHour,
        'endMinute': endMinute,
        'color': color,
        'tags': tags,
        'iconKey': iconKey,
      };

  factory ScheduleEvent.fromJson(Map<String, dynamic> json) => ScheduleEvent(
        id: json['id'] as String,
        groupId: json['groupId'] as String?,
        date: DateTime.parse(json['date'] as String),
        title: json['title'] as String,
        note: json['note'] as String?,
        startHour: json['startHour'] as int?,
        startMinute: json['startMinute'] as int?,
        endHour: json['endHour'] as int?,
        endMinute: json['endMinute'] as int?,
        color: json['color'] as int?,
        tags: (json['tags'] as List?)?.map((e) => e.toString()).toList() ?? const <String>[],
        iconKey: json['iconKey'] as String?,
      );
}

class ScheduleStore {
  static const _prefsKey = 'schedule_events';
  static final ScheduleStore instance = ScheduleStore._internal();
  final ValueNotifier<List<ScheduleEvent>> events = ValueNotifier<List<ScheduleEvent>>(<ScheduleEvent>[]);

  ScheduleStore._internal();

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) {
      events.value = <ScheduleEvent>[];
      return;
    }
    try {
      final list = (jsonDecode(raw) as List<dynamic>).map((e) => ScheduleEvent.fromJson(e as Map<String, dynamic>)).toList();
      events.value = list;
    } catch (_) {
      events.value = <ScheduleEvent>[];
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final data = jsonEncode(events.value.map((e) => e.toJson()).toList());
    await prefs.setString(_prefsKey, data);
  }

  Future<void> addEvent(ScheduleEvent event) async {
    events.value = [...events.value, event];
    await _persist();
    await _insertDb(event);
  }

  Future<void> updateEvent(ScheduleEvent updated) async {
    events.value = events.value.map((e) => e.id == updated.id ? updated : e).toList();
    await _persist();
    await _updateDb(updated);
  }

  Future<void> deleteEvent(String id) async {
    events.value = events.value.where((e) => e.id != id).toList();
    await _persist();
    final dbClient = await AcademyDbService.instance.db;
    await dbClient.delete('schedule_events', where: 'id = ?', whereArgs: [id]);
  }

  List<ScheduleEvent> eventsOn(DateTime date) {
    final y = date.year, m = date.month, d = date.day;
    return events.value.where((e) => e.date.year == y && e.date.month == m && e.date.day == d).toList();
  }

  int eventsCountOn(DateTime date) => eventsOn(date).length;

  // ==== DB Sync ====
  Future<void> _insertDb(ScheduleEvent e) async {
    final dbClient = await AcademyDbService.instance.db;
    await dbClient.insert('schedule_events', {
      'id': e.id,
      'group_id': e.groupId,
      'date': DateTime(e.date.year, e.date.month, e.date.day).toIso8601String(),
      'title': e.title,
      'note': e.note,
      'start_hour': e.startHour,
      'start_minute': e.startMinute,
      'end_hour': e.endHour,
      'end_minute': e.endMinute,
      'color': e.color,
      'tags': e.tags.isEmpty ? null : jsonEncode(e.tags),
      'icon_key': e.iconKey,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
  }

  Future<void> _updateDb(ScheduleEvent e) async {
    final dbClient = await AcademyDbService.instance.db;
    await dbClient.update('schedule_events', {
      'group_id': e.groupId,
      'date': DateTime(e.date.year, e.date.month, e.date.day).toIso8601String(),
      'title': e.title,
      'note': e.note,
      'start_hour': e.startHour,
      'start_minute': e.startMinute,
      'end_hour': e.endHour,
      'end_minute': e.endMinute,
      'color': e.color,
      'tags': e.tags.isEmpty ? null : jsonEncode(e.tags),
      'icon_key': e.iconKey,
      'updated_at': DateTime.now().toIso8601String(),
    }, where: 'id = ?', whereArgs: [e.id]);
  }

  Future<void> loadFromDb() async {
    final dbClient = await AcademyDbService.instance.db;
    final rows = await dbClient.query('schedule_events');
    events.value = rows.map((r) => ScheduleEvent(
      id: r['id'] as String,
      groupId: r['group_id'] as String?,
      date: DateTime.parse(r['date'] as String),
      title: r['title'] as String,
      note: r['note'] as String?,
      startHour: r['start_hour'] as int?,
      startMinute: r['start_minute'] as int?,
      endHour: r['end_hour'] as int?,
      endMinute: r['end_minute'] as int?,
      color: r['color'] as int?,
      tags: (r['tags'] as String?) != null ? List<String>.from(jsonDecode(r['tags'] as String)) : <String>[],
      iconKey: r['icon_key'] as String?,
    )).toList();
  }

  Future<void> deleteGroup(String groupId) async {
    events.value = events.value.where((e) => e.groupId != groupId).toList();
    await _persist();
    final dbClient = await AcademyDbService.instance.db;
    await dbClient.delete('schedule_events', where: 'group_id = ?', whereArgs: [groupId]);
  }

  String newGroupId() => const Uuid().v4();
}


