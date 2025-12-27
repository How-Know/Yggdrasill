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
  /// 시범 수업(1회성) 출석(등원/하원) 시각(로컬). null이면 미기록.
  final DateTime? arrivalTime;
  final DateTime? departureTime;
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
    this.arrivalTime,
    this.departureTime,
    required this.weekStart,
    required this.dayIndex,
    required this.hour,
    required this.minute,
    this.count = 1,
  });

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  ConsultTrialLessonSlot copyWith({
    String? title,
    DateTime? weekStart,
    int? dayIndex,
    int? hour,
    int? minute,
    int? count,
    DateTime? arrivalTime,
    DateTime? departureTime,
    bool clearArrivalTime = false,
    bool clearDepartureTime = false,
  }) {
    return ConsultTrialLessonSlot(
      id: id,
      sourceNoteId: sourceNoteId,
      title: title ?? this.title,
      createdAt: createdAt,
      arrivalTime: clearArrivalTime ? null : (arrivalTime ?? this.arrivalTime),
      departureTime: clearDepartureTime ? null : (departureTime ?? this.departureTime),
      weekStart: weekStart ?? this.weekStart,
      dayIndex: dayIndex ?? this.dayIndex,
      hour: hour ?? this.hour,
      minute: minute ?? this.minute,
      count: count ?? this.count,
    );
  }

  factory ConsultTrialLessonSlot.fromJson(Map<String, dynamic> j) {
    // v1 -> v2 마이그레이션:
    // - 예전 키: completedAt(=등원으로 취급)
    final completedAtStr = (j['completedAt'] as String?) ?? '';
    final completedAt = completedAtStr.isNotEmpty ? DateTime.tryParse(completedAtStr) : null;

    final arrivalStr = (j['arrivalTime'] as String?) ?? '';
    final departureStr = (j['departureTime'] as String?) ?? '';
    final arrival = arrivalStr.isNotEmpty ? DateTime.tryParse(arrivalStr) : null;
    final departure = departureStr.isNotEmpty ? DateTime.tryParse(departureStr) : null;
    return ConsultTrialLessonSlot(
      id: j['id'] as String,
      sourceNoteId: (j['noteId'] as String?) ?? '',
      title: (j['title'] as String?) ?? '시범 수업',
      createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
      arrivalTime: arrival ?? completedAt,
      departureTime: departure,
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
        if (arrivalTime != null) 'arrivalTime': arrivalTime!.toIso8601String(),
        if (departureTime != null) 'departureTime': departureTime!.toIso8601String(),
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
  bool hasArrivedForNote(String noteId) =>
      _slots.any((s) => s.sourceNoteId == noteId && s.arrivalTime != null);
  bool hasAnyForNote(String noteId) => _slots.any((s) => s.sourceNoteId == noteId);
  List<ConsultTrialLessonSlot> slotsForNote(String noteId) =>
      _slots.where((s) => s.sourceNoteId == noteId).toList();

  List<ConsultTrialLessonSlot> slotsForDate(DateTime date) {
    final d = _dateOnly(date);
    return _slots.where((s) {
      final wk = _dateOnly(s.weekStart);
      final slotDate = _dateOnly(wk.add(Duration(days: s.dayIndex)));
      return slotDate == d;
    }).toList();
  }

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

    // ✅ 재저장/마이그레이션 시에도 등원/하원 기록이 유지되도록,
    // (weekStart + slotKey) 기준으로 기존 레코드를 매핑한다.
    final existingForNoteByKey = <String, ConsultTrialLessonSlot>{};
    for (final s in _slots) {
      if (s.sourceNoteId != noteId) continue;
      final wk0 = _dateOnly(s.weekStart).toIso8601String().split('T').first;
      final k0 = slotKey(s.dayIndex, s.hour, s.minute);
      existingForNoteByKey['$wk0:$k0'] = s;
    }

    // 기존 noteId 슬롯 제거
    final next = _slots.where((s) => s.sourceNoteId != noteId).toList();

    // 신규 슬롯 추가 (선택한 주에만 표시)
    final now = DateTime.now();
    final wk = _dateOnly(weekStart);
    final wkKey = wk.toIso8601String().split('T').first;
    final sortedKeys = slotKeys.toList()..sort();
    for (final k in sortedKeys) {
      final parts = k.split('-');
      if (parts.length != 2) continue;
      final dayIdx = int.tryParse(parts[0]);
      final hm = parts[1].split(':');
      if (dayIdx == null || hm.length != 2) continue;
      final hh = int.tryParse(hm[0]);
      final mm = int.tryParse(hm[1]);
      if (hh == null || mm == null) continue;
      // ✅ ID는 결정적으로(weekStart + slotKey 기반) 만들어, 출석(등원/하원) 기록이 재저장 시에도 유지되도록 한다.
      final id = '$noteId:$wkKey:$k';
      final prev = existingForNoteByKey['$wkKey:$k'];
      next.add(ConsultTrialLessonSlot(
        id: id,
        sourceNoteId: noteId,
        title: title,
        createdAt: now,
        arrivalTime: prev?.arrivalTime,
        departureTime: prev?.departureTime,
        weekStart: wk,
        dayIndex: dayIdx,
        hour: hh,
        minute: mm,
        count: 1,
      ));
    }

    _slots = next;
    slotsNotifier.value = List.unmodifiable(_slots);
    await _write();
  }

  Future<void> setArrived({
    required String slotId,
    required bool arrived,
  }) async {
    await load();
    final idx = _slots.indexWhere((s) => s.id == slotId);
    if (idx == -1) return;
    final cur = _slots[idx];
    final nextSlot = arrived
        ? cur.copyWith(arrivalTime: DateTime.now())
        : cur.copyWith(clearArrivalTime: true, clearDepartureTime: true);
    final next = [..._slots];
    next[idx] = nextSlot;
    _slots = next;
    slotsNotifier.value = List.unmodifiable(_slots);
    await _write();
  }

  Future<void> setLeaved({
    required String slotId,
    required bool leaved,
  }) async {
    await load();
    final idx = _slots.indexWhere((s) => s.id == slotId);
    if (idx == -1) return;
    final cur = _slots[idx];
    if (leaved) {
      final now = DateTime.now();
      final nextSlot = cur.copyWith(
        arrivalTime: cur.arrivalTime ?? now,
        departureTime: now,
      );
      final next = [..._slots];
      next[idx] = nextSlot;
      _slots = next;
      slotsNotifier.value = List.unmodifiable(_slots);
      await _write();
      return;
    }
    // 하원 취소: departure만 지우고, arrival은 유지
    final nextSlot = cur.copyWith(clearDepartureTime: true);
    final next = [..._slots];
    next[idx] = nextSlot;
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


