import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import 'package:yggdrasill_manager/services/course_map_service.dart';

/// 시험용 단원 틀: 이름과 아래 단원.
class U {
  const U(this.name, [this.children = const []]);

  final String name;
  final List<U> children;
}

class _FakeCourse {
  _FakeCourse(this.id, this.name, this.level, this.code, this.key, this.seeded, this.sort);

  final String id;
  String name;
  String level;
  String? code;
  final String? key;
  final bool seeded;
  int sort;
  int version = 1;
  int? archived;
  DateTime updated = DateTime(2026, 10, 23, 9);
}

class _FakeUnit {
  _FakeUnit(this.id, this.courseId, this.parentId, this.name, this.sort);

  final String id;
  final String courseId;
  String? parentId;
  String name;
  int sort;

  /// 보관 묶음 번호. 같은 번호끼리 함께 보관됐다.
  int? archived;
}

class _FakePlacement {
  _FakePlacement(this.id, this.unitId, this.conceptId, this.sort, this.origin, this.note);

  final String id;
  String unitId;
  final String conceptId;
  int sort;
  String origin;
  String? note;
}

/// 서버 RPC(`course_map_*`)와 같은 규칙으로 움직이는 메모리 저장소.
class FakeCourseMapBackend implements CourseMapBackend {
  final Map<String, _FakeCourse> _courses = {};
  final Map<String, _FakeUnit> _units = {};
  int _seq = 0;
  int _batch = 0;

  /// 바꾸기를 부른 횟수(성공·실패 모두).
  int writes = 0;
  List<CourseMapUnitInput>? lastUnits;
  List<String>? lastArchive;

  /// 다음 읽기·저장을 이 오류로 실패시킨다.
  CourseMapException? failList;
  CourseMapException? failGet;
  CourseMapException? failSave;

  /// 저장을 이 동안 멈춰 둔다.
  Completer<void>? holdSave;

  final Map<String, _FakePlacement> _placements = {};
  final Map<String, String> _concepts = {};
  CourseMapException? failPlacements;
  CourseMapException? failOverview;

  /// 배치 읽기를 부른 횟수.
  int placementReads = 0;

  /// 최근 변경(새것부터). 시험에서 바로 채운다.
  final List<CourseChange> changes = [];
  CourseMapException? failChanges;
  List<List<String>?> changeKinds = [];

  /// 한 번에 읽는 수를 줄여 더 보기를 시험한다.
  int? changePage;

  String _id(String prefix) => '$prefix${++_seq}';

  String addCourse(String name, {String level = '고', String? code = 'rev_2022', String? key, bool seeded = true, List<U> units = const []}) {
    final id = _id('c');
    final sort = _courses.values.where((c) => c.archived == null).length;
    _courses[id] = _FakeCourse(id, name, level, code, key, seeded, sort);
    void put(String? parent, List<U> list) {
      for (var i = 0; i < list.length; i++) {
        final uid = _id('u');
        _units[uid] = _FakeUnit(uid, id, parent, list[i].name, i);
        put(uid, list[i].children);
      }
    }

    put(null, units);
    return id;
  }

  /// 같은 과정 안에서 이름으로 찾는다(시험에서만).
  String unitId(String courseId, String name) =>
      _units.values.firstWhere((u) => u.courseId == courseId && u.name == name).id;

  int version(String courseId) => _courses[courseId]!.version;
  String? unitName(String id) => _units[id]?.name;
  String? parentOf(String id) => _units[id]?.parentId;
  bool isArchived(String id) => _units[id]?.archived != null;

  /// 다른 곳에서 저장한 것처럼 판만 올린다.
  void bumpVersion(String courseId) => _courses[courseId]!.version += 1;

  /// 다른 곳(Think 카드 승인 등)에서 단원 이름을 바꾼 것처럼.
  void renameElsewhere(String unitId, String name) {
    final u = _units[unitId]!;
    u.name = name;
    _courses[u.courseId]!.version += 1;
  }

  String addConcept(String name) {
    final id = _id('k');
    _concepts[id] = name;
    return id;
  }

  /// 시험 준비용으로 바로 놓는다.
  String place(String unitId, String conceptId, {String origin = 'owner', String? note}) {
    final id = _id('p');
    _placements[id] = _FakePlacement(id, unitId, conceptId, _inUnit(unitId).length, origin, note);
    return id;
  }

  List<String> namesIn(String unitId) => [for (final p in _inUnit(unitId)) _concepts[p.conceptId]!];

  List<_FakePlacement> _inUnit(String unitId) =>
      _placements.values.where((p) => p.unitId == unitId).toList()..sort((a, b) => a.sort.compareTo(b.sort));

  void _renumberUnit(String unitId) {
    final list = _inUnit(unitId);
    for (var i = 0; i < list.length; i++) {
      list[i].sort = i;
    }
  }

  List<CourseMapPlacement> _placementList(String courseId) {
    final out = <CourseMapPlacement>[];
    for (final u in _units.values.where((u) => u.courseId == courseId && u.archived == null)) {
      for (final p in _inUnit(u.id)) {
        out.add(CourseMapPlacement.fromJson({
          'id': p.id,
          'unit_id': p.unitId,
          'concept_id': p.conceptId,
          'name': _concepts[p.conceptId],
          'sort': p.sort,
          'origin': p.origin,
          'note': p.note,
          'type': '정의',
          'sources': 0,
        }));
      }
    }
    return out;
  }

  _FakeUnit _activeUnit(String unitId) {
    final u = _units[unitId];
    if (u == null || u.archived != null) _fail('course_placement_unit_not_found');
    if (_courses[u.courseId]!.archived != null) _fail('course_map_archived');
    return u;
  }

  _FakePlacement _placementRow(String id) {
    final p = _placements[id];
    if (p == null) _fail('course_placement_not_found');
    return p;
  }

  List<_FakeUnit> _kids(String courseId, String? parentId, {bool active = true}) => _units.values
      .where((u) => u.courseId == courseId && u.parentId == parentId && (u.archived == null) == active)
      .toList()
    ..sort((a, b) => a.sort.compareTo(b.sort));

  int _depth(String id) {
    var d = 0;
    String? cur = id;
    while (cur != null) {
      d += 1;
      cur = _units[cur]!.parentId;
    }
    return d;
  }

  Never _fail(String code) => throw PostgrestException(message: code, code: 'P0001');

  Map<String, dynamic> _courseJson(_FakeCourse c, {bool counts = false}) {
    final out = <String, dynamic>{
      'id': c.id,
      'name': c.name,
      'school_level': c.level,
      'curriculum_code': c.code,
      'course_key': c.key,
      'seeded': c.seeded,
      'sort_order': c.sort,
      'version': c.version,
      'updated_at': c.updated.toUtc().toIso8601String(),
      'archived_at': c.archived == null ? null : DateTime(2026, 10, 23, 10).toUtc().toIso8601String(),
    };
    if (counts) {
      final n = [0, 0, 0];
      for (final u in _units.values.where((u) => u.courseId == c.id && u.archived == null)) {
        n[_depth(u.id) - 1] += 1;
      }
      out['counts'] = n;
    }
    return out;
  }

  CourseMapDetail _detail(String courseId) {
    final c = _courses[courseId]!;
    final units = <Map<String, dynamic>>[];
    void walk(String? parent, int depth) {
      for (final u in _kids(courseId, parent)) {
        units.add({'id': u.id, 'parent_id': u.parentId, 'depth': depth, 'name': u.name, 'sort_order': u.sort});
        walk(u.id, depth + 1);
      }
    }

    walk(null, 1);
    final archived = <Map<String, dynamic>>[];
    for (final u in _units.values.where((u) => u.courseId == courseId && u.archived != null)) {
      final parent = u.parentId == null ? null : _units[u.parentId];
      if (parent != null && parent.archived == u.archived) continue;
      final path = <String>[];
      var cur = parent;
      while (cur != null) {
        path.insert(0, cur.name);
        cur = cur.parentId == null ? null : _units[cur.parentId];
      }
      archived.add({
        'id': u.id,
        'parent_id': u.parentId,
        'depth': _depth(u.id),
        'name': u.name,
        'archived_at': DateTime(2026, 10, 23, 10).toUtc().toIso8601String(),
        'parent_active': parent == null || parent.archived == null,
        'path': path,
        'count': _batchUnder(u.id, u.archived!).length,
      });
    }
    return CourseMapDetail.fromJson({'course': _courseJson(c), 'units': units, 'archived': archived});
  }

  List<String> _batchUnder(String id, int batch) => [
        id,
        for (final k in _units.values.where((x) => x.parentId == id && x.archived == batch)) ..._batchUnder(k.id, batch),
      ];

  List<CourseMapCourse> _list() {
    final active = _courses.values.where((c) => c.archived == null).toList()..sort((a, b) => a.sort.compareTo(b.sort));
    final archived = _courses.values.where((c) => c.archived != null).toList();
    return [for (final c in [...active, ...archived]) CourseMapCourse.fromJson(_courseJson(c, counts: true))];
  }

  void _renumber() {
    final active = _courses.values.where((c) => c.archived == null).toList()..sort((a, b) => a.sort.compareTo(b.sort));
    for (var i = 0; i < active.length; i++) {
      active[i].sort = i;
    }
  }

  _FakeCourse _lock(CourseMapCourse base) {
    final c = _courses[base.id];
    if (c == null) _fail('course_map_not_found');
    if (c.version != base.version) _fail('course_map_stale');
    if (c.archived != null) _fail('course_map_archived');
    return c;
  }

  @override
  Future<List<CourseMapCourse>> list() async {
    final f = failList;
    if (f != null) throw f;
    return _list();
  }

  @override
  Future<CourseMapDetail> get(String courseId) async {
    final f = failGet;
    if (f != null) throw f;
    if (!_courses.containsKey(courseId)) _fail('course_map_not_found');
    return _detail(courseId);
  }

  @override
  Future<CourseMapDetail> create({required String name, required String schoolLevel, String? curriculumCode}) async {
    writes += 1;
    final id = addCourse(name, level: schoolLevel, code: curriculumCode, seeded: false);
    return _detail(id);
  }

  @override
  Future<CourseMapDetail> save({
    required CourseMapCourse base,
    required String name,
    required String schoolLevel,
    required String? curriculumCode,
    required List<CourseMapUnitInput> units,
    required List<String> archive,
  }) async {
    writes += 1;
    lastUnits = units;
    lastArchive = archive;
    final hold = holdSave;
    if (hold != null) await hold.future;
    final f = failSave;
    if (f != null) throw f;
    final c = _lock(base);
    final ids = {for (final u in units) u.id};
    if (ids.length != units.length) _fail('course_map_bad_units');
    for (final u in units) {
      final old = _units[u.id];
      if (old != null && old.courseId != c.id) _fail('course_map_unit_foreign');
      if (old != null && old.archived != null) _fail('course_map_unit_archived');
      if (u.parentId != null && !ids.contains(u.parentId)) _fail('course_map_bad_parent');
    }
    final active = _units.values.where((u) => u.courseId == c.id && u.archived == null).map((u) => u.id).toSet();
    for (final a in archive) {
      if (!active.contains(a)) _fail('course_map_unit_not_found');
      if (ids.contains(a)) _fail('course_map_unit_conflict');
    }
    if (active.any((id) => !ids.contains(id) && !archive.contains(id))) _fail('course_map_unit_missing');

    final batch = ++_batch;
    for (final a in archive) {
      _units[a]!.archived = batch;
    }
    final pos = <String?, int>{};
    for (final u in units) {
      final n = pos[u.parentId] = (pos[u.parentId] ?? -1) + 1;
      final row = _units[u.id] ??= _FakeUnit(u.id, c.id, u.parentId, u.name, n);
      row
        ..parentId = u.parentId
        ..name = u.name
        ..sort = n;
    }
    c
      ..name = name
      ..level = schoolLevel
      ..code = curriculumCode
      ..version += 1
      ..updated = c.updated.add(const Duration(minutes: 1));
    return _detail(c.id);
  }

  @override
  Future<CourseMapDetail> restoreUnit({required CourseMapCourse base, required String unitId}) async {
    writes += 1;
    final c = _lock(base);
    final u = _units[unitId];
    if (u == null || u.courseId != c.id || u.archived == null) _fail('course_map_unit_not_found');
    final parent = u.parentId == null ? null : _units[u.parentId];
    if (parent != null && parent.archived != null) _fail('course_map_parent_archived');
    final batch = _batchUnder(u.id, u.archived!);
    u.sort = _kids(c.id, u.parentId).length;
    for (final id in batch) {
      _units[id]!.archived = null;
    }
    c.version += 1;
    return _detail(c.id);
  }

  @override
  Future<List<CourseMapCourse>> archiveCourse(CourseMapCourse base) async {
    writes += 1;
    final c = _lock(base);
    c
      ..archived = ++_batch
      ..version += 1;
    _renumber();
    return _list();
  }

  @override
  Future<List<CourseMapCourse>> restoreCourse(String courseId) async {
    writes += 1;
    final c = _courses[courseId];
    if (c == null || c.archived == null) _fail('course_map_not_found');
    c
      ..archived = null
      ..sort = _courses.values.length
      ..version += 1;
    _renumber();
    return _list();
  }

  @override
  Future<List<CourseMapCourse>> reorder({required List<String> expected, required List<String> ids}) async {
    writes += 1;
    final now = [for (final c in _list()) if (!c.archived) c.id];
    if (now.join(',') != expected.join(',')) _fail('course_map_list_stale');
    if (ids.toSet().length != ids.length || ids.toSet().difference(now.toSet()).isNotEmpty || ids.length != now.length) {
      _fail('course_map_bad_order');
    }
    for (var i = 0; i < ids.length; i++) {
      _courses[ids[i]]!.sort = i;
    }
    return _list();
  }

  @override
  Future<List<CourseMapPlacement>> placements(String courseId) async {
    placementReads += 1;
    final f = failPlacements;
    if (f != null) throw f;
    if (!_courses.containsKey(courseId)) _fail('course_map_not_found');
    return _placementList(courseId);
  }

  @override
  Future<CourseMapPlacementOverview> placementOverview() async {
    final f = failOverview;
    if (f != null) throw f;
    final per = <String, int>{};
    final placed = <String>{};
    for (final p in _placements.values) {
      final u = _units[p.unitId]!;
      if (u.archived != null) continue;
      per[u.courseId] = (per[u.courseId] ?? 0) + 1;
      if (_courses[u.courseId]!.archived == null) placed.add(p.conceptId);
    }
    return CourseMapPlacementOverview(concepts: _concepts.length, placed: placed.length, perCourse: per);
  }

  @override
  Future<List<CourseMapPlacement>> addPlacements({required String unitId, required List<String> conceptIds}) async {
    writes += 1;
    final u = _activeUnit(unitId);
    final ids = conceptIds.toSet().toList();
    if (ids.isEmpty || ids.length > 100) _fail('course_placement_bad_concepts');
    for (final c in ids) {
      if (!_concepts.containsKey(c)) _fail('course_placement_concept_not_found');
      if (_inUnit(unitId).any((p) => p.conceptId == c)) _fail('course_placement_exists');
    }
    for (final c in ids) {
      place(unitId, c);
    }
    return _placementList(u.courseId);
  }

  @override
  Future<List<CourseMapPlacement>> removePlacement(String placementId) async {
    writes += 1;
    final p = _placementRow(placementId);
    final u = _activeUnit(p.unitId);
    _placements.remove(placementId);
    _renumberUnit(p.unitId);
    return _placementList(u.courseId);
  }

  @override
  Future<List<CourseMapPlacement>> movePlacement({required String placementId, required String unitId}) async {
    writes += 1;
    final p = _placementRow(placementId);
    final from = _activeUnit(p.unitId);
    final to = _activeUnit(unitId);
    if (from.courseId != to.courseId) _fail('course_placement_unit_foreign');
    if (p.unitId == unitId) _fail('course_placement_same_unit');
    if (_inUnit(unitId).any((x) => x.conceptId == p.conceptId)) _fail('course_placement_exists');
    final old = p.unitId;
    p
      ..unitId = unitId
      ..sort = _inUnit(unitId).length
      ..origin = 'owner'
      ..note = null;
    _renumberUnit(old);
    return _placementList(to.courseId);
  }

  @override
  Future<List<CourseMapPlacement>> reorderPlacements({required String unitId, required List<String> ids}) async {
    writes += 1;
    final u = _activeUnit(unitId);
    final now = _inUnit(unitId).map((p) => p.id).toSet();
    if (ids.length != now.length || ids.toSet().length != ids.length || !now.containsAll(ids)) {
      _fail('course_placement_stale');
    }
    for (var i = 0; i < ids.length; i++) {
      _placements[ids[i]]!.sort = i;
    }
    return _placementList(u.courseId);
  }

  @override
  Future<List<CourseMapConceptHit>> searchConcepts(String query) async {
    final q = query.trim();
    return [
      for (final e in _concepts.entries)
        if (e.value.contains(q)) CourseMapConceptHit(id: e.key, name: e.value),
    ];
  }

  @override
  Future<CourseChangePage> recentChanges({List<String>? kinds, CourseChange? olderThan, int limit = 60}) async {
    changeKinds.add(kinds);
    final f = failChanges;
    if (f != null) throw f;
    if (kinds != null && (kinds.isEmpty || kinds.any((k) => !const {'placement', 'content', 'statement'}.contains(k)))) {
      _fail('course_changes_bad_kinds');
    }
    var list = [for (final c in changes) if (kinds == null || kinds.contains(c.kind)) c];
    if (olderThan != null) list = list.sublist(list.indexWhere((c) => c.key == olderThan.key) + 1);
    final n = changePage ?? limit;
    return CourseChangePage(items: list.take(n).toList(), more: list.length > n);
  }
}
