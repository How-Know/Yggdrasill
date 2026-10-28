import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'auth_service.dart';
import 'course_map_service.dart';

const int kCourseMapMaxDepth = 3;
const int kCourseMapNameMax = 80;
const int kCourseMapCourseNameMax = 40;

const List<String> kCourseMapLevelNames = ['대단원', '중단원', '소단원'];

String courseMapRoman(int n) {
  const table = [(10, 'X'), (9, 'IX'), (5, 'V'), (4, 'IV'), (1, 'I')];
  var rest = n;
  final out = StringBuffer();
  for (final (value, mark) in table) {
    while (rest >= value) {
      out.write(mark);
      rest -= value;
    }
  }
  return out.toString();
}

class CourseMapNode {
  CourseMapNode({required this.id, required this.name, this.parentId, this.isNew = false});

  final String id;
  String? parentId;
  String name;

  /// 아직 저장하지 않은 새 단원. 빼면 보관하지 않고 바로 없어진다.
  final bool isNew;
}

/// 한 과정의 편집본. 저장본([base])과 비교해 바뀐 곳을 세고, 저장할 목록을 만든다.
/// 번호(I, 1., (1))와 단계 번호는 순서로 셀 뿐 저장하지 않는다.
class CourseMapDraft {
  CourseMapDraft(this.base, {String? selectedId, Set<String>? expanded}) {
    for (final u in base.units) {
      _nodes[u.id] = CourseMapNode(id: u.id, name: u.name, parentId: u.parentId);
      (_kids[u.parentId] ??= []).add(u.id);
      (_baseKids[u.parentId] ??= []).add(u.id);
      _baseName[u.id] = u.name;
      _baseParent[u.id] = u.parentId;
    }
    name = base.course.name;
    schoolLevel = base.course.schoolLevel;
    curriculumCode = base.course.curriculumCode;
    this.selectedId = selectedId != null && _nodes.containsKey(selectedId) ? selectedId : null;
    if (expanded == null) {
      this.expanded.addAll(_nodes.keys.where((id) => childrenOf(id).isNotEmpty));
    } else {
      this.expanded.addAll(expanded.where(_nodes.containsKey));
    }
  }

  final CourseMapDetail base;
  final Map<String, CourseMapNode> _nodes = {};
  final Map<String?, List<String>> _kids = {};
  final Map<String?, List<String>> _baseKids = {};
  final Map<String, String> _baseName = {};
  final Map<String, String?> _baseParent = {};

  /// 이번에 보관할 저장된 단원(아래 단원 포함, 하나하나).
  final Set<String> archive = {};

  /// 위로·아래로·옮기기로 자리를 바꾼 단원(표시용).
  final Set<String> _moved = {};

  late String name;
  late String schoolLevel;
  String? curriculumCode;

  String? selectedId;
  final Set<String> expanded = {};

  CourseMapCourse get course => base.course;

  CourseMapNode? node(String id) => _nodes[id];
  List<String> childrenOf(String? parentId) => _kids[parentId] ?? const [];
  int get unitCount => _nodes.length;

  int depthOf(String id) {
    var d = 0;
    String? cur = id;
    while (cur != null) {
      d += 1;
      cur = _nodes[cur]?.parentId;
    }
    return d;
  }

  /// 이 단원부터 맨 아래까지 단계 수(아래 단원이 없으면 1).
  int heightOf(String id) {
    var h = 0;
    for (final k in childrenOf(id)) {
      final kh = heightOf(k);
      if (kh > h) h = kh;
    }
    return h + 1;
  }

  /// [ancestor]가 [id] 자신이거나 그 위 단원인지.
  bool isSelfOrAncestor(String ancestor, String id) {
    String? cur = id;
    while (cur != null) {
      if (cur == ancestor) return true;
      cur = _nodes[cur]?.parentId;
    }
    return false;
  }

  List<String> subtree(String id) => [id, for (final k in childrenOf(id)) ...subtree(k)];

  /// 위에서 아래로 전부.
  List<String> flatIds() => [for (final r in childrenOf(null)) ...subtree(r)];

  List<String> pathNames(String id) {
    final out = <String>[];
    String? cur = _nodes[id]?.parentId;
    while (cur != null) {
      out.insert(0, _nodes[cur]?.name ?? '');
      cur = _nodes[cur]?.parentId;
    }
    return out;
  }

  int indexOf(String id) => childrenOf(_nodes[id]?.parentId).indexOf(id);

  String numberLabel(String id) {
    final i = indexOf(id) + 1;
    return switch (depthOf(id)) { 1 => courseMapRoman(i), 2 => '$i.', _ => '($i)' };
  }

  /// 아래 단원이 없는 단원에 위에서부터 1, 2, 3 … 을 붙인다. 아래 단원이 있으면 그 범위.
  Map<String, (int, int)> steps() {
    final out = <String, (int, int)>{};
    var n = 0;
    (int, int) walk(String id) {
      final kids = childrenOf(id);
      if (kids.isEmpty) {
        n += 1;
        return out[id] = (n, n);
      }
      final first = n + 1;
      for (final k in kids) {
        walk(k);
      }
      return out[id] = (first, n);
    }

    for (final r in childrenOf(null)) {
      walk(r);
    }
    return out;
  }

  bool isRenamed(String id) {
    final n = _nodes[id];
    return n != null && !n.isNew && n.name.trim() != _baseName[id];
  }

  bool isMoved(String id) {
    final n = _nodes[id];
    if (n == null || n.isNew) return false;
    return n.parentId != _baseParent[id] || (_moved.contains(id) && _orderChanged(n.parentId));
  }

  /// 원래부터 이 부모 아래 있던 저장된 단원끼리의 순서가 바뀌었는지.
  bool _orderChanged(String? parentId) {
    bool stayed(String id) => _nodes[id]?.parentId == parentId && _baseParent[id] == parentId;
    final now = childrenOf(parentId).where(stayed).toList();
    final was = (_baseKids[parentId] ?? const <String>[]).where(stayed).toList();
    return !listEquals(now, was);
  }

  bool get metaChanged =>
      name.trim() != base.course.name || schoolLevel != base.course.schoolLevel || curriculumCode != base.course.curriculumCode;

  int get newCount => _nodes.values.where((n) => n.isNew).length;

  /// 바뀐 곳 수: 새 단원, 이름 바꾼 단원, 자리 바꾼 단원, 보관할 단원, 과정 정보.
  int get changeCount {
    var n = newCount + archive.length + (metaChanged ? 1 : 0);
    for (final id in _nodes.keys) {
      if (isRenamed(id) || isMoved(id)) n += 1;
    }
    if (n == 0 && _structureChanged()) n = 1;
    return n;
  }

  bool _structureChanged() {
    final parents = {..._kids.keys, ..._baseKids.keys};
    for (final p in parents) {
      if (_orderChanged(p)) return true;
    }
    return false;
  }

  bool get dirty => changeCount > 0;

  String defaultName(int depth) => '새 ${kCourseMapLevelNames[depth - 1]}';

  /// [parentId] 아래(없으면 대단원)에 새 단원을 넣는다. [after]가 있으면 그 바로 뒤.
  String? addUnit(String? parentId, {String? after, String Function()? newId}) {
    final depth = parentId == null ? 1 : depthOf(parentId) + 1;
    if (depth > kCourseMapMaxDepth) return null;
    final id = (newId ?? const Uuid().v4)();
    _nodes[id] = CourseMapNode(id: id, name: defaultName(depth), parentId: parentId, isNew: true);
    final list = _kids[parentId] ??= [];
    final at = after == null ? -1 : list.indexOf(after);
    if (at < 0) {
      list.add(id);
    } else {
      list.insert(at + 1, id);
    }
    if (parentId != null) expanded.add(parentId);
    selectedId = id;
    return id;
  }

  bool move(String id, int delta) {
    final n = _nodes[id];
    if (n == null) return false;
    final list = _kids[n.parentId]!;
    final i = list.indexOf(id);
    final j = i + delta;
    if (j < 0 || j >= list.length) return false;
    list
      ..removeAt(i)
      ..insert(j, id);
    _moved.add(id);
    return true;
  }

  /// 옮길 수 없으면 이유를 돌려준다. [newParentId]가 null이면 대단원으로.
  String? whyCannotReparent(String id, String? newParentId) {
    if (newParentId != null) {
      if (!_nodes.containsKey(newParentId)) return '없는 단원입니다.';
      if (isSelfOrAncestor(id, newParentId)) return '자기 자신이나 자기 아래 단원으로는 옮길 수 없습니다.';
    }
    final top = newParentId == null ? 1 : depthOf(newParentId) + 1;
    if (top + heightOf(id) - 1 > kCourseMapMaxDepth) return '대·중·소 세 단계를 넘습니다.';
    return null;
  }

  String? reparent(String id, String? newParentId) {
    final n = _nodes[id];
    if (n == null) return '없는 단원입니다.';
    final why = whyCannotReparent(id, newParentId);
    if (why != null) return why;
    _kids[n.parentId]?.remove(id);
    (_kids[newParentId] ??= []).add(id);
    n.parentId = newParentId;
    _moved.add(id);
    if (newParentId != null) expanded.add(newParentId);
    return null;
  }

  /// 단원과 아래 단원을 뺀다. 저장된 단원은 보관 목록에, 새 단원은 그냥 없어진다. 보관할 저장된 단원 수를 돌려준다.
  int remove(String id) {
    final n = _nodes[id];
    if (n == null) return 0;
    final ids = subtree(id);
    final siblings = _kids[n.parentId]!;
    final i = siblings.indexOf(id);
    var saved = 0;
    for (final x in ids) {
      if (!_nodes[x]!.isNew) {
        archive.add(x);
        saved += 1;
      }
    }
    siblings.remove(id);
    for (final x in ids) {
      _nodes.remove(x);
      _kids.remove(x);
      _moved.remove(x);
      expanded.remove(x);
    }
    if (selectedId != null && ids.contains(selectedId)) {
      selectedId = siblings.isEmpty ? n.parentId : siblings[i.clamp(0, siblings.length - 1)];
    }
    return saved;
  }

  /// 저장 전에 막을 것. 없으면 null.
  String? validate() {
    final courseName = name.trim();
    if (courseName.isEmpty || courseName.length > kCourseMapCourseNameMax) {
      return '과정 이름은 비울 수 없고 $kCourseMapCourseNameMax자까지입니다.';
    }
    for (final id in flatIds()) {
      final v = _nodes[id]!.name.trim();
      if (v.isEmpty) return '이름이 빈 단원이 있습니다.';
      if (v.length > kCourseMapNameMax) return '단원 이름은 $kCourseMapNameMax자까지입니다: ${v.substring(0, 12)}…';
    }
    return null;
  }

  List<CourseMapUnitInput> payload() => [
        for (final id in flatIds())
          CourseMapUnitInput(id: id, parentId: _nodes[id]!.parentId, name: _nodes[id]!.name.trim()),
      ];
}

/// 단원 하나와 그 아래 단원 전체에 놓인 개념 수(같은 개념은 한 번), 맨 아래 단원 수와 그중 개념이 놓인 곳 수.
class CourseUnitTally {
  const CourseUnitTally({required this.concepts, required this.leaves, required this.filledLeaves});

  final int concepts;
  final int leaves;
  final int filledLeaves;
}

/// 편집본의 지금 단원 구조로 센다. 편집본에 없는 단원(보관할 단원 등)에 놓인 개념은 세지 않는다.
Map<String, CourseUnitTally> courseUnitTallies(CourseMapDraft d, List<CourseMapPlacement> placements) {
  final byUnit = <String, Set<String>>{};
  for (final p in placements) {
    (byUnit[p.unitId] ??= {}).add(p.conceptId);
  }
  final out = <String, CourseUnitTally>{};
  (Set<String>, int, int) walk(String id) {
    final concepts = <String>{...?byUnit[id]};
    final kids = d.childrenOf(id);
    var leaves = 0;
    var filled = 0;
    if (kids.isEmpty) {
      leaves = 1;
      filled = concepts.isEmpty ? 0 : 1;
    }
    for (final k in kids) {
      final (c, l, f) = walk(k);
      concepts.addAll(c);
      leaves += l;
      filled += f;
    }
    out[id] = CourseUnitTally(concepts: concepts.length, leaves: leaves, filledLeaves: filled);
    return (concepts, leaves, filled);
  }

  for (final r in d.childrenOf(null)) {
    walk(r);
  }
  return out;
}

/// 과정 탐색도 화면 상태. 메뉴를 옮겨 화면이 다시 만들어져도 과정별 편집본·선택·펼침이 남는다.
class CourseMapController extends ChangeNotifier {
  CourseMapController._(this._backendFactory);

  static final CourseMapController instance =
      CourseMapController._(() => SupabaseCourseMapBackend(Supabase.instance.client));

  @visibleForTesting
  factory CourseMapController.forTest(CourseMapBackend backend, {String Function()? newId}) =>
      CourseMapController._(() => backend)
        .._started = true
        .._newId = newId;

  final CourseMapBackend Function() _backendFactory;
  CourseMapBackend? _backendCache;
  CourseMapBackend get _backend => _backendCache ??= _backendFactory();
  String Function()? _newId;

  bool _started = false;
  String? _userId;
  int _epoch = 0;

  List<CourseMapCourse> courses = const [];
  bool listLoading = false;
  bool listLoaded = false;
  CourseMapException? listError;

  /// 과정 만들기·순서·보관처럼 목록을 바로 바꾸는 중.
  bool listBusy = false;
  String? selectedCourseId;

  final Map<String, CourseMapDraft> _drafts = {};
  final Set<String> _courseLoading = {};
  final Map<String, CourseMapException> _courseErrors = {};
  final Map<String, CourseMapException> _saveErrors = {};

  /// 저장·되살리기 중인 과정.
  String? busyCourseId;

  /// 과정별 단원에 놓인 개념. 읽지 못했으면 없고 [placementError]가 남는다(예전 목록을 대신 보이지 않는다).
  final Map<String, List<CourseMapPlacement>> _placements = {};
  final Set<String> _placementLoading = {};
  final Map<String, CourseMapException> _placementErrors = {};

  /// 놓기·빼기·옮기기·순서 바꾸기 중인 과정.
  String? placementBusyCourseId;

  /// 전체 개념 중 놓인 수. 읽지 못하면 null.
  CourseMapPlacementOverview? overview;

  /// 흐름 목록에서 놓인 개념 줄을 펼친 단원(과정별). 화면 상태라 저장할 변경으로 세지 않는다.
  final Map<String, Set<String>> _conceptsOpen = {};

  List<CourseMapCourse> get activeCourses => [for (final c in courses) if (!c.archived) c];
  List<CourseMapCourse> get archivedCourses => [for (final c in courses) if (c.archived) c];

  CourseMapCourse? courseById(String id) => courses.where((c) => c.id == id).firstOrNull;
  CourseMapCourse? get selectedCourse => selectedCourseId == null ? null : courseById(selectedCourseId!);

  CourseMapDraft? draftOf(String courseId) => _drafts[courseId];
  CourseMapDraft? get draft => selectedCourseId == null ? null : _drafts[selectedCourseId!];
  bool courseLoading(String courseId) => _courseLoading.contains(courseId);
  CourseMapException? courseError(String courseId) => _courseErrors[courseId];
  CourseMapException? saveError(String courseId) => _saveErrors[courseId];
  bool isDirty(String courseId) => _drafts[courseId]?.dirty ?? false;
  bool get anyDirty => _drafts.values.any((d) => d.dirty);
  List<String> get dirtyCourseNames => [
        for (final d in _drafts.values)
          if (d.dirty) d.name.trim().isEmpty ? d.course.name : d.name.trim(),
      ];
  bool get busy => busyCourseId != null || listBusy;

  List<CourseMapPlacement>? placementsOf(String courseId) => _placements[courseId];
  bool placementLoading(String courseId) => _placementLoading.contains(courseId);
  CourseMapException? placementError(String courseId) => _placementErrors[courseId];
  bool placementBusy(String courseId) => placementBusyCourseId == courseId;

  /// 단원 안 순서대로.
  List<CourseMapPlacement> placementsIn(String courseId, String unitId) =>
      [for (final p in _placements[courseId] ?? const <CourseMapPlacement>[]) if (p.unitId == unitId) p]
        ..sort((a, b) => a.sort.compareTo(b.sort));

  int placementCount(String courseId, String unitId) =>
      (_placements[courseId] ?? const <CourseMapPlacement>[]).where((p) => p.unitId == unitId).length;

  bool conceptsOpen(String courseId, String unitId) => _conceptsOpen[courseId]?.contains(unitId) ?? false;

  /// 개념이 놓인 단원(편집본에 있는 것)이 모두 펼쳐졌는지.
  bool allConceptsOpen(String courseId) {
    final open = _conceptsOpen[courseId] ?? const <String>{};
    final d = _drafts[courseId];
    final units = {
      for (final p in _placements[courseId] ?? const <CourseMapPlacement>[])
        if (d?.node(p.unitId) != null) p.unitId,
    };
    return units.isNotEmpty && units.every(open.contains);
  }

  void toggleConcepts(String courseId, String unitId) {
    final open = _conceptsOpen[courseId] ??= {};
    if (!open.remove(unitId)) open.add(unitId);
    notifyListeners();
  }

  /// 개념이 놓인 단원을 모두 펼치거나 접는다. 펼칠 때는 그 위 단원도 펼쳐 줄이 보이게 한다.
  void setAllConceptsOpen(String courseId, bool open) {
    final set = _conceptsOpen[courseId] ??= {};
    set.clear();
    if (open) {
      final units = {for (final p in _placements[courseId] ?? const <CourseMapPlacement>[]) p.unitId};
      final d = _drafts[courseId];
      for (final u in units) {
        if (d == null || d.node(u) == null) continue;
        set.add(u);
        var cur = d.node(u)!.parentId;
        while (cur != null) {
          d.expanded.add(cur);
          cur = d.node(cur)?.parentId;
        }
      }
    }
    notifyListeners();
  }

  /// 최근 변경(배치 기록·본문 고친 기록·서술 확정 기록). 읽기만 하고 화면 상태에 남기지 않는다.
  Future<CourseChangePage> recentChanges({List<String>? kinds, CourseChange? olderThan}) async {
    try {
      return await _backend.recentChanges(kinds: kinds, olderThan: olderThan);
    } catch (e) {
      throw CourseMapException.from(e);
    }
  }

  void ensureStarted() {
    if (_started) return;
    _started = true;
    _userId = AuthService.currentUser?.id;
    AuthService.authStateChanges.listen((s) {
      final uid = s.session?.user.id;
      if (uid == _userId) return;
      _userId = uid;
      _reset();
      if (uid != null) unawaited(loadList());
    });
  }

  void _reset() {
    _epoch += 1;
    courses = const [];
    listLoading = false;
    listLoaded = false;
    listError = null;
    listBusy = false;
    selectedCourseId = null;
    _drafts.clear();
    _courseLoading.clear();
    _courseErrors.clear();
    _saveErrors.clear();
    busyCourseId = null;
    _placements.clear();
    _placementLoading.clear();
    _placementErrors.clear();
    placementBusyCourseId = null;
    overview = null;
    _conceptsOpen.clear();
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() => _reset();

  /// 읽지 못하면 오류만 남긴다. 예전 목록이나 코드에 적힌 목록으로 대신 보이지 않는다.
  Future<void> loadList() async {
    final epoch = _epoch;
    listLoading = true;
    listError = null;
    notifyListeners();
    try {
      final list = await _backend.list();
      if (epoch != _epoch) return;
      courses = list;
      listLoaded = true;
      final active = activeCourses;
      if (selectedCourseId == null || !active.any((c) => c.id == selectedCourseId)) {
        selectedCourseId = active.isEmpty ? null : active.first.id;
      }
    } catch (e) {
      if (epoch != _epoch) return;
      listError = CourseMapException.from(e);
      listLoaded = false;
      courses = const [];
    } finally {
      if (epoch == _epoch) {
        listLoading = false;
        notifyListeners();
      }
    }
    if (epoch == _epoch && listLoaded) unawaited(loadOverview());
    final id = selectedCourseId;
    if (epoch == _epoch && id != null && !_drafts.containsKey(id)) await loadCourse(id);
  }

  Future<void> loadOverview() async {
    final epoch = _epoch;
    try {
      final o = await _backend.placementOverview();
      if (epoch != _epoch) return;
      overview = o;
    } catch (_) {
      if (epoch != _epoch) return;
      overview = null;
    }
    notifyListeners();
  }

  Future<void> loadPlacements(String courseId) async {
    final epoch = _epoch;
    _placementLoading.add(courseId);
    _placementErrors.remove(courseId);
    notifyListeners();
    try {
      final list = await _backend.placements(courseId);
      if (epoch != _epoch) return;
      _placements[courseId] = list;
    } catch (e) {
      if (epoch != _epoch) return;
      _placements.remove(courseId);
      _placementErrors[courseId] = CourseMapException.from(e);
    } finally {
      if (epoch == _epoch) {
        _placementLoading.remove(courseId);
        notifyListeners();
      }
    }
  }

  /// 개념 상세에서 기준 단원 줄을 뺐을 때처럼 배치만 바뀌었을 때. 읽어 둔 과정만 다시 읽는다.
  Future<void> reloadPlacements() async {
    if (!_started) return;
    final ids = {..._drafts.keys, ..._placements.keys};
    for (final id in ids) {
      await loadPlacements(id);
    }
    if (listLoaded) await loadOverview();
  }

  /// Think 카드 승인처럼 이 화면 밖에서 과정·배치가 바뀌었을 때. 저장 안 한 편집이 있는 과정은 편집본을 두고 배치만 다시 읽는다.
  /// 그 편집을 저장하면 판이 달라 막히고, 저장 줄에서 최신 저장본을 불러올 수 있다.
  Future<void> refreshAfterExternalChange({String? courseId}) async {
    if (!_started || (!listLoaded && listError == null)) return;
    await loadList();
    final ids = courseId != null ? [courseId] : {..._drafts.keys, ..._placements.keys}.toList();
    for (final id in ids) {
      final d = _drafts[id];
      if (d != null && !d.dirty && busyCourseId != id) {
        await loadCourse(id);
      } else if (d != null || _placements.containsKey(id)) {
        await loadPlacements(id);
      }
    }
  }

  void selectCourse(String courseId) {
    if (selectedCourseId == courseId) return;
    selectedCourseId = courseId;
    notifyListeners();
    if (!_drafts.containsKey(courseId) && !_courseLoading.contains(courseId)) unawaited(loadCourse(courseId));
  }

  /// 서버 저장본을 읽어 편집본을 새로 만든다. 저장 안 한 편집은 버려지므로 화면에서 먼저 묻는다.
  Future<void> loadCourse(String courseId) async {
    final epoch = _epoch;
    _courseLoading.add(courseId);
    _courseErrors.remove(courseId);
    notifyListeners();
    try {
      final detail = await _backend.get(courseId);
      if (epoch != _epoch) return;
      final old = _drafts[courseId];
      _drafts[courseId] = CourseMapDraft(detail, selectedId: old?.selectedId, expanded: old?.expanded);
      _saveErrors.remove(courseId);
      _replaceCourse(detail);
      unawaited(loadPlacements(courseId));
    } catch (e) {
      if (epoch != _epoch) return;
      _courseErrors[courseId] = CourseMapException.from(e);
    } finally {
      if (epoch == _epoch) {
        _courseLoading.remove(courseId);
        notifyListeners();
      }
    }
  }

  void _replaceCourse(CourseMapDetail detail) {
    final counts = [0, 0, 0];
    for (final u in detail.units) {
      if (u.depth >= 1 && u.depth <= 3) counts[u.depth - 1] += 1;
    }
    final c = detail.course;
    courses = [
      for (final x in courses)
        if (x.id == c.id)
          CourseMapCourse(
            id: c.id,
            name: c.name,
            schoolLevel: c.schoolLevel,
            curriculumCode: c.curriculumCode,
            courseKey: c.courseKey,
            seeded: c.seeded,
            sortOrder: x.sortOrder,
            version: c.version,
            updatedAt: c.updatedAt,
            archivedAt: c.archivedAt,
            counts: counts,
          )
        else
          x
    ];
  }

  void _edit(void Function(CourseMapDraft d) change) {
    final d = draft;
    if (d == null || busyCourseId == d.course.id) return;
    change(d);
    notifyListeners();
  }

  void selectUnit(String? id) => _edit((d) => d.selectedId = id);

  void toggleExpanded(String id) => _edit((d) => d.expanded.contains(id) ? d.expanded.remove(id) : d.expanded.add(id));

  void setAllExpanded(bool open) => _edit((d) {
        d.expanded.clear();
        if (open) d.expanded.addAll(d.flatIds().where((id) => d.childrenOf(id).isNotEmpty));
      });

  void rename(String id, String name) => _edit((d) => d.node(id)?.name = name);

  void setCourseName(String v) => _edit((d) => d.name = v);
  void setSchoolLevel(String v) => _edit((d) => d.schoolLevel = v);
  void setCurriculumCode(String? v) => _edit((d) => d.curriculumCode = v);

  String? addUnit(String? parentId, {String? after}) {
    String? id;
    _edit((d) => id = d.addUnit(parentId, after: after, newId: _newId));
    return id;
  }

  void moveUnit(String id, int delta) => _edit((d) => d.move(id, delta));

  String? reparent(String id, String? newParentId) {
    String? why;
    _edit((d) => why = d.reparent(id, newParentId));
    return why;
  }

  int removeUnit(String id) {
    var saved = 0;
    _edit((d) => saved = d.remove(id));
    return saved;
  }

  /// 편집본을 저장본으로 되돌린다(선택·펼침은 남김).
  void discard() {
    final d = draft;
    if (d == null || busyCourseId != null) return;
    _drafts[d.course.id] = CourseMapDraft(d.base, selectedId: d.selectedId, expanded: d.expanded);
    _saveErrors.remove(d.course.id);
    notifyListeners();
  }

  /// 실패하면 편집본은 그대로 두고 오류를 남긴다.
  Future<bool> save() async {
    final d = draft;
    if (d == null || busy || !d.dirty) return false;
    final courseId = d.course.id;
    final invalid = d.validate();
    if (invalid != null) {
      _saveErrors[courseId] = CourseMapException('invalid', invalid);
      notifyListeners();
      return false;
    }
    final epoch = _epoch;
    busyCourseId = courseId;
    _saveErrors.remove(courseId);
    notifyListeners();
    try {
      final detail = await _backend.save(
        base: d.course,
        name: d.name.trim(),
        schoolLevel: d.schoolLevel,
        curriculumCode: d.curriculumCode,
        units: d.payload(),
        archive: d.archive.toList(),
      );
      if (epoch != _epoch) return false;
      _drafts[courseId] = CourseMapDraft(detail, selectedId: d.selectedId, expanded: d.expanded);
      _replaceCourse(detail);
      if (d.archive.isNotEmpty) {
        unawaited(loadPlacements(courseId));
        unawaited(loadOverview());
      }
      return true;
    } catch (e) {
      if (epoch != _epoch) return false;
      _saveErrors[courseId] = CourseMapException.from(e);
      return false;
    } finally {
      if (epoch == _epoch) {
        busyCourseId = null;
        notifyListeners();
      }
    }
  }

  /// 저장 안 한 편집이 있으면 막는다(되살리기는 바로 저장되어 판이 바뀐다).
  Future<String?> restoreUnit(String unitId) async {
    final d = draft;
    if (d == null || busy) return null;
    if (d.dirty) return '저장하지 않은 편집이 있습니다. 저장하거나 되돌린 뒤 되살리세요.';
    final courseId = d.course.id;
    final epoch = _epoch;
    busyCourseId = courseId;
    notifyListeners();
    try {
      final detail = await _backend.restoreUnit(base: d.course, unitId: unitId);
      if (epoch != _epoch) return null;
      final next = CourseMapDraft(detail, selectedId: unitId, expanded: d.expanded);
      var cur = next.node(unitId)?.parentId;
      while (cur != null) {
        next.expanded.add(cur);
        cur = next.node(cur)?.parentId;
      }
      next.expanded.addAll(next.subtree(unitId).where((id) => next.childrenOf(id).isNotEmpty));
      _drafts[courseId] = next;
      _replaceCourse(detail);
      unawaited(loadPlacements(courseId));
      unawaited(loadOverview());
      return null;
    } catch (e) {
      if (epoch != _epoch) return null;
      return CourseMapException.from(e).message;
    } finally {
      if (epoch == _epoch) {
        busyCourseId = null;
        notifyListeners();
      }
    }
  }

  Future<String?> _listAction(Future<List<CourseMapCourse>> Function() run, {String? select}) async {
    if (busy) return null;
    final epoch = _epoch;
    listBusy = true;
    notifyListeners();
    try {
      final list = await run();
      if (epoch != _epoch) return null;
      courses = list;
      final active = activeCourses;
      if (select != null && active.any((c) => c.id == select)) {
        selectedCourseId = select;
      } else if (selectedCourseId == null || !active.any((c) => c.id == selectedCourseId)) {
        selectedCourseId = active.isEmpty ? null : active.first.id;
      }
      return null;
    } catch (e) {
      if (epoch != _epoch) return null;
      return CourseMapException.from(e).message;
    } finally {
      if (epoch == _epoch) {
        listBusy = false;
        notifyListeners();
        final id = selectedCourseId;
        if (id != null && !_drafts.containsKey(id) && !_courseLoading.contains(id)) unawaited(loadCourse(id));
      }
    }
  }

  Future<String?> createCourse({required String name, required String schoolLevel, String? curriculumCode}) async {
    String? id;
    final problem = await _listAction(() async {
      final detail = await _backend.create(name: name.trim(), schoolLevel: schoolLevel, curriculumCode: curriculumCode);
      id = detail.course.id;
      _drafts[detail.course.id] = CourseMapDraft(detail);
      return _backend.list();
    });
    if (problem == null && id != null && courseById(id!) != null) {
      selectedCourseId = id;
      notifyListeners();
    }
    return problem;
  }

  Future<String?> moveCourse(String courseId, int delta) {
    final ids = [for (final c in activeCourses) c.id];
    final i = ids.indexOf(courseId);
    final j = i + delta;
    if (i < 0 || j < 0 || j >= ids.length) return Future.value(null);
    final next = [...ids]
      ..removeAt(i)
      ..insert(j, courseId);
    return _listAction(() => _backend.reorder(expected: ids, ids: next), select: courseId);
  }

  /// 저장 안 한 편집이 있는 과정은 보관하지 않는다.
  Future<String?> archiveCourse(String courseId) async {
    final d = _drafts[courseId];
    final c = courseById(courseId);
    if (c == null) return null;
    if (d != null && d.dirty) return '저장하지 않은 편집이 있습니다. 저장하거나 되돌린 뒤 보관하세요.';
    final problem = await _listAction(() => _backend.archiveCourse(d?.course ?? c));
    if (problem == null) _drafts.remove(courseId);
    return problem;
  }

  Future<String?> restoreCourse(String courseId) {
    _drafts.remove(courseId);
    return _listAction(() => _backend.restoreCourse(courseId), select: courseId);
  }

  // --- 단원에 놓인 개념(바로 저장된다. 단원 편집본과 따로 간다) ---

  Future<String?> _placementAction(Future<List<CourseMapPlacement>> Function() run) async {
    final courseId = selectedCourseId;
    if (courseId == null || placementBusyCourseId != null || busyCourseId == courseId) return null;
    final epoch = _epoch;
    placementBusyCourseId = courseId;
    notifyListeners();
    try {
      final list = await run();
      if (epoch != _epoch) return null;
      _placements[courseId] = list;
      _placementErrors.remove(courseId);
      unawaited(loadOverview());
      return null;
    } catch (e) {
      if (epoch != _epoch) return null;
      final err = CourseMapException.from(e);
      if (err.code == 'course_placement_stale' || err.code == 'course_placement_not_found') {
        unawaited(loadPlacements(courseId));
      }
      return err.message;
    } finally {
      if (epoch == _epoch) {
        placementBusyCourseId = null;
        notifyListeners();
      }
    }
  }

  Future<String?> addPlacements(String unitId, List<String> conceptIds) =>
      _placementAction(() => _backend.addPlacements(unitId: unitId, conceptIds: conceptIds));

  Future<String?> removePlacement(String placementId) => _placementAction(() => _backend.removePlacement(placementId));

  Future<String?> movePlacement(String placementId, String unitId) =>
      _placementAction(() => _backend.movePlacement(placementId: placementId, unitId: unitId));

  /// 단원 안에서 한 칸 위(-1)·아래(+1)로.
  Future<String?> shiftPlacement(String unitId, String placementId, int delta) {
    final courseId = selectedCourseId;
    if (courseId == null) return Future.value(null);
    final ids = [for (final p in placementsIn(courseId, unitId)) p.id];
    final i = ids.indexOf(placementId);
    final j = i + delta;
    if (i < 0 || j < 0 || j >= ids.length) return Future.value(null);
    ids
      ..removeAt(i)
      ..insert(j, placementId);
    return _placementAction(() => _backend.reorderPlacements(unitId: unitId, ids: ids));
  }

  Future<List<CourseMapConceptHit>> searchConcepts(String query) => _backend.searchConcepts(query);
}
