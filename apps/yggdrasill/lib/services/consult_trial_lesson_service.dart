import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 시범 수업(일회성) 일정 저장소.
///
/// - 희망 수업(문의)과 달리 "반복"이 아니라, **선택한 주차(weekStart)에서만** 표시된다.
/// - 시간표 정원(인원) 카운트에도 반영되며, 기본수업시간(lessonDuration)만큼 30분 블록으로 확장된다.
class ConsultTrialLessonSlot {
  final String id;
  final String sourceNoteId;
  final String title; // 문의 노트 제목
  final DateTime createdAt;
  final DateTime weekStart; // date-only Monday (해당 주에만 표시)
  final int dayIndex; // 0=Mon..6=Sun
  final int hour; // 0..23
  final int minute; // 0..59
  final int count; // 기본 1

  const ConsultTrialLessonSlot({
    required this.id,
    required this.sourceNoteId,
    required this.title,
    required this.createdAt,
    required this.weekStart,
    required this.dayIndex,
    required this.hour,
    required this.minute,
    this.count = 1,
  });

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  factory ConsultTrialLessonSlot.fromJson(Map<String, dynamic> j) {
    return ConsultTrialLessonSlot(
      id: j['id'] as String,
      sourceNoteId: (j['noteId'] as String?) ?? '',
      title: (j['title'] as String?) ?? '시범 수업',
      createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
      weekStart: _dateOnly(DateTime.tryParse(j['weekStart'] as String? ?? '') ?? DateTime.now()),
      dayIndex: (j['dayIndex'] as num).toInt(),
      hour: (j['hour'] as num).toInt(),
      minute: (j['minute'] as num).toInt(),
      count: (j['count'] as num?)?.toInt() ?? 1,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'noteId': sourceNoteId,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'weekStart': _dateOnly(weekStart).toIso8601String(),
        'dayIndex': dayIndex,
        'hour': hour,
        'minute': minute,
        'count': count,
      };
}

class ConsultTrialLessonService {
  ConsultTrialLessonService._internal() {
    Future.microtask(load);
  }
  static final ConsultTrialLessonService instance = ConsultTrialLessonService._internal();

  static const String _dirName = 'consult_notes';
  static const String _fileName = 'trial_lessons.json';

  final ValueNotifier<List<ConsultTrialLessonSlot>> slotsNotifier = ValueNotifier<List<ConsultTrialLessonSlot>>([]);
  bool _loaded = false;
  List<ConsultTrialLessonSlot> _slots = <ConsultTrialLessonSlot>[];

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
  static String slotKey(int dayIndex, int hour, int minute) => '$dayIndex-$hour:$minute';

  List<ConsultTrialLessonSlot> get slots => List.unmodifiable(_slots);

  Future<Directory> _resolveDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, _dirName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _file() async {
    final dir = await _resolveDir();
    return File(p.join(dir.path, _fileName));
  }

  Future<void> load() async {
    if (_loaded) return;
    try {
      final f = await _file();
      if (!await f.exists()) {
        _slots = <ConsultTrialLessonSlot>[];
        slotsNotifier.value = List.unmodifiable(_slots);
        _loaded = true;
        return;
      }
      final map = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final list = (map['slots'] as List<dynamic>? ?? const <dynamic>[]).cast<Map<String, dynamic>>();
      _slots = list.map(ConsultTrialLessonSlot.fromJson).toList();
      slotsNotifier.value = List.unmodifiable(_slots);
      _loaded = true;
    } catch (_) {
      _slots = <ConsultTrialLessonSlot>[];
      slotsNotifier.value = List.unmodifiable(_slots);
      _loaded = true;
    }
  }

  Future<void> _write() async {
    final f = await _file();
    final map = <String, dynamic>{
      'version': 1,
      'slots': _slots.map((s) => s.toJson()).toList(),
    };
    await f.writeAsString(const JsonEncoder.withIndent('  ').convert(map), flush: true);
  }

  Future<void> upsertForNote({
    required String noteId,
    required String title,
    required DateTime weekStart,
    required Set<String> slotKeys,
  }) async {
    await load();

    // 기존 noteId 슬롯 제거
    final next = _slots.where((s) => s.sourceNoteId != noteId).toList();

    // 신규 슬롯 추가 (선택한 주에만 표시)
    final now = DateTime.now();
    int idx = 0;
    for (final k in slotKeys) {
      final parts = k.split('-');
      if (parts.length != 2) continue;
      final dayIdx = int.tryParse(parts[0]);
      final hm = parts[1].split(':');
      if (dayIdx == null || hm.length != 2) continue;
      final hh = int.tryParse(hm[0]);
      final mm = int.tryParse(hm[1]);
      if (hh == null || mm == null) continue;
      next.add(ConsultTrialLessonSlot(
        id: '$noteId:$idx',
        sourceNoteId: noteId,
        title: title,
        createdAt: now,
        weekStart: _dateOnly(weekStart),
        dayIndex: dayIdx,
        hour: hh,
        minute: mm,
        count: 1,
      ));
      idx += 1;
    }

    _slots = next;
    slotsNotifier.value = List.unmodifiable(_slots);
    await _write();
  }

  Future<void> removeForNote(String noteId) async {
    await load();
    final next = _slots.where((s) => s.sourceNoteId != noteId).toList();
    if (next.length == _slots.length) return;
    _slots = next;
    slotsNotifier.value = List.unmodifiable(_slots);
    await _write();
  }

  /// 해당 주(weekStartDate)에서만 표시되는 슬롯들을 key별로 묶어 반환.
  Map<String, List<ConsultTrialLessonSlot>> slotsBySlotKeyForWeek(DateTime weekStartDate) {
    final wk = _dateOnly(weekStartDate);
    final out = <String, List<ConsultTrialLessonSlot>>{};
    for (final s in _slots) {
      if (_dateOnly(s.weekStart) != wk) continue;
      final k = slotKey(s.dayIndex, s.hour, s.minute);
      (out[k] ??= <ConsultTrialLessonSlot>[]).add(s);
    }
    return out;
  }

  /// 해당 주(weekStartDate)에서만 표시되는 슬롯들을 `lessonDurationMinutes`만큼 30분 블록으로 확장해 합산.
  Map<String, int> countMapForWeekExpanded(
    DateTime weekStartDate, {
    required int lessonDurationMinutes,
    int blockMinutes = 30,
  }) {
    final wk = _dateOnly(weekStartDate);
    if (lessonDurationMinutes <= 0 || blockMinutes <= 0) return <String, int>{};

    final int rawCount = (lessonDurationMinutes / blockMinutes).ceil();
    final int blockCount = rawCount.clamp(1, (24 * 60 / blockMinutes).floor());

    final out = <String, int>{};
    for (final s in _slots) {
      if (_dateOnly(s.weekStart) != wk) continue;
      final int base = s.hour * 60 + s.minute;
      for (int i = 0; i < blockCount; i++) {
        final int minutes = base + blockMinutes * i;
        if (minutes >= 24 * 60) break;
        final int hh = minutes ~/ 60;
        final int mm = minutes % 60;
        final k = slotKey(s.dayIndex, hh, mm);
        out[k] = (out[k] ?? 0) + s.count;
      }
    }
    return out;
  }
}


