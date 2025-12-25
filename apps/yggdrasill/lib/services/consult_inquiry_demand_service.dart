import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// "문의(등록 문의)"에서 선택한 희망 수업시간을 시간표 정원(인원) 카운트에 반영하기 위한 로컬 저장소.
///
/// - 한 문의가 월/목 15:00처럼 여러 슬롯을 선택할 수 있으므로, 슬롯 단위 레코드로 저장한다.
/// - `startWeek`(월요일) 이후의 모든 주차에 반복 적용된다(요구사항: "해당 주차 이후에 모두 반영").
class ConsultInquiryDemandSlot {
  final String id;
  /// 원본 문의 노트 id(라벨/카운트의 출처). 없으면 레거시(구버전)로 간주.
  final String sourceNoteId;
  /// 시간표에 표시할 라벨(요구사항: 문의 노트 제목)
  final String title;
  final DateTime createdAt;
  final DateTime startWeek; // date-only Monday
  final int dayIndex; // 0=Mon..6=Sun
  final int hour; // 0..23
  final int minute; // 0..59
  final int count; // 기본 1

  const ConsultInquiryDemandSlot({
    required this.id,
    required this.sourceNoteId,
    required this.title,
    required this.createdAt,
    required this.startWeek,
    required this.dayIndex,
    required this.hour,
    required this.minute,
    this.count = 1,
  });

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  ConsultInquiryDemandSlot copyWith({
    String? title,
    DateTime? startWeek,
    int? dayIndex,
    int? hour,
    int? minute,
    int? count,
  }) {
    return ConsultInquiryDemandSlot(
      id: id,
      sourceNoteId: sourceNoteId,
      title: title ?? this.title,
      createdAt: createdAt,
      startWeek: startWeek ?? this.startWeek,
      dayIndex: dayIndex ?? this.dayIndex,
      hour: hour ?? this.hour,
      minute: minute ?? this.minute,
      count: count ?? this.count,
    );
  }

  factory ConsultInquiryDemandSlot.fromJson(Map<String, dynamic> j) {
    return ConsultInquiryDemandSlot(
      id: j['id'] as String,
      sourceNoteId: (j['noteId'] as String?) ?? '',
      title: (j['title'] as String?) ?? '희망 수업',
      createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
      startWeek: _dateOnly(DateTime.tryParse(j['startWeek'] as String? ?? '') ?? DateTime.now()),
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
        'startWeek': _dateOnly(startWeek).toIso8601String(),
        'dayIndex': dayIndex,
        'hour': hour,
        'minute': minute,
        'count': count,
      };
}

class ConsultInquiryDemandService {
  ConsultInquiryDemandService._internal() {
    // 앱 시작 후 비동기로 로드(빌드는 동기이므로 초기에는 0으로 보였다가 로드 후 갱신됨)
    Future.microtask(load);
  }
  static final ConsultInquiryDemandService instance = ConsultInquiryDemandService._internal();

  static const String _dirName = 'consult_notes';
  static const String _fileName = 'inquiry_demand.json';

  final ValueNotifier<List<ConsultInquiryDemandSlot>> slotsNotifier = ValueNotifier<List<ConsultInquiryDemandSlot>>([]);
  bool _loaded = false;
  List<ConsultInquiryDemandSlot> _slots = <ConsultInquiryDemandSlot>[];

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  static String slotKey(int dayIndex, int hour, int minute) => '$dayIndex-$hour:$minute';

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

  List<ConsultInquiryDemandSlot> get slots => List.unmodifiable(_slots);

  Future<void> load() async {
    if (_loaded) return;
    try {
      final f = await _file();
      if (!await f.exists()) {
        _slots = <ConsultInquiryDemandSlot>[];
        slotsNotifier.value = List.unmodifiable(_slots);
        _loaded = true;
        return;
      }
      final map = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final list = (map['slots'] as List<dynamic>? ?? const <dynamic>[]).cast<Map<String, dynamic>>();
      _slots = list.map(ConsultInquiryDemandSlot.fromJson).toList();

      // v2 마이그레이션: 예전 버전에서 생성된 레거시 희망수업 라벨은 noteId가 없어
      // 삭제(문의 노트 삭제)와 연결될 수 없으므로 자동 정리한다.
      final legacyCount = _slots.where((s) => s.sourceNoteId.isEmpty).length;
      if (legacyCount > 0) {
        _slots = _slots.where((s) => s.sourceNoteId.isNotEmpty).toList();
        // 파일도 즉시 정리(다음 실행에도 남지 않도록)
        try {
          await _write();
        } catch (_) {}
      }

      slotsNotifier.value = List.unmodifiable(_slots);
      _loaded = true;
    } catch (_) {
      _slots = <ConsultInquiryDemandSlot>[];
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

  Future<void> addSlots({
    required DateTime startWeek,
    required Iterable<ConsultInquiryDemandSlot> slots,
  }) async {
    await load();
    final next = <ConsultInquiryDemandSlot>[..._slots, ...slots];
    _slots = next;
    slotsNotifier.value = List.unmodifiable(_slots);
    await _write();
  }

  Future<void> upsertForNote({
    required String noteId,
    required String title,
    required DateTime startWeek,
    required Set<String> slotKeys,
  }) async {
    await load();
    // 1) 기존 noteId 슬롯 제거
    final next = _slots.where((s) => s.sourceNoteId != noteId).toList();

    // 2) 신규 슬롯 추가
    final now = DateTime.now();
    int idx = 0;
    for (final k in slotKeys) {
      // k: '$dayIdx-$hour:$minute'
      final parts = k.split('-');
      if (parts.length != 2) continue;
      final dayIdx = int.tryParse(parts[0]);
      final hm = parts[1].split(':');
      if (dayIdx == null || hm.length != 2) continue;
      final hh = int.tryParse(hm[0]);
      final mm = int.tryParse(hm[1]);
      if (hh == null || mm == null) continue;
      next.add(ConsultInquiryDemandSlot(
        id: '$noteId:$idx',
        sourceNoteId: noteId,
        title: title,
        createdAt: now,
        startWeek: _dateOnly(startWeek),
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

  /// `weekStartDate`(해당 주 월요일) 기준으로 "startWeek <= weekStartDate"인 슬롯들을 key별로 묶어 반환.
  Map<String, List<ConsultInquiryDemandSlot>> slotsBySlotKeyForWeek(DateTime weekStartDate) {
    final wk = _dateOnly(weekStartDate);
    final out = <String, List<ConsultInquiryDemandSlot>>{};
    for (final s in _slots) {
      if (_dateOnly(s.startWeek).isAfter(wk)) continue;
      final k = slotKey(s.dayIndex, s.hour, s.minute);
      (out[k] ??= <ConsultInquiryDemandSlot>[]).add(s);
    }
    return out;
  }

  /// `weekStartDate`(해당 주 월요일) 기준으로 "startWeek <= weekStartDate"인 슬롯들을 합산해 반환.
  Map<String, int> countMapForWeek(DateTime weekStartDate) {
    final wk = _dateOnly(weekStartDate);
    final out = <String, int>{};
    for (final s in _slots) {
      if (_dateOnly(s.startWeek).isAfter(wk)) continue;
      final k = slotKey(s.dayIndex, s.hour, s.minute);
      out[k] = (out[k] ?? 0) + s.count;
    }
    return out;
  }

  /// `weekStartDate`(해당 주 월요일) 기준으로 "startWeek <= weekStartDate"인 슬롯들을
  /// `lessonDurationMinutes`(기본수업시간) 만큼 30분 블록으로 확장하여 합산해 반환.
  ///
  /// 예) lessonDuration=120, 15:00 시작이면 15:00/15:30/16:00/16:30 모든 블록에 +1
  Map<String, int> countMapForWeekExpanded(
    DateTime weekStartDate, {
    required int lessonDurationMinutes,
    int blockMinutes = 30,
  }) {
    final wk = _dateOnly(weekStartDate);
    if (lessonDurationMinutes <= 0 || blockMinutes <= 0) {
      return countMapForWeek(weekStartDate);
    }

    final int rawCount = (lessonDurationMinutes / blockMinutes).ceil();
    final int blockCount = rawCount.clamp(1, (24 * 60 / blockMinutes).floor());

    final out = <String, int>{};
    for (final s in _slots) {
      if (_dateOnly(s.startWeek).isAfter(wk)) continue;
      final int base = s.hour * 60 + s.minute;
      for (int i = 0; i < blockCount; i++) {
        final int minutes = base + blockMinutes * i;
        if (minutes >= 24 * 60) break; // 하루를 넘기면 중단
        final int hh = minutes ~/ 60;
        final int mm = minutes % 60;
        final k = slotKey(s.dayIndex, hh, mm);
        out[k] = (out[k] ?? 0) + s.count;
      }
    }
    return out;
  }
}


