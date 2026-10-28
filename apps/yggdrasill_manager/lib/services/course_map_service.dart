import 'package:supabase_flutter/supabase_flutter.dart';

/// 기준 과정 탐색도 저장소(`docs/architecture/course-map.md`). 표는 읽기만, 바꾸기는 RPC로만 한다.

DateTime? _time(Object? v) => v == null ? null : DateTime.tryParse(v.toString())?.toLocal();

class CourseMapCourse {
  const CourseMapCourse({
    required this.id,
    required this.name,
    required this.schoolLevel,
    required this.version,
    this.curriculumCode,
    this.courseKey,
    this.seeded = false,
    this.sortOrder = 0,
    this.updatedAt,
    this.archivedAt,
    this.counts = const [0, 0, 0],
  });

  final String id;
  final String name;
  final String schoolLevel;
  final String? curriculumCode;

  /// 교재 과정 목록의 키(M1-1 …). 이름으로 맞추지 않는다.
  final String? courseKey;

  /// 초기 자료(예전 문항로드맵 목록)로 들어온 과정.
  final bool seeded;
  final int sortOrder;
  final int version;
  final DateTime? updatedAt;
  final DateTime? archivedAt;

  /// 깊이별 살아 있는 단원 수(대·중·소). 목록에서만 채운다.
  final List<int> counts;

  bool get archived => archivedAt != null;

  factory CourseMapCourse.fromJson(Map<String, dynamic> j) {
    final counts = j['counts'];
    return CourseMapCourse(
      id: j['id'] as String,
      name: (j['name'] ?? '') as String,
      schoolLevel: (j['school_level'] ?? '중') as String,
      curriculumCode: j['curriculum_code'] as String?,
      courseKey: j['course_key'] as String?,
      seeded: j['seeded'] == true,
      sortOrder: (j['sort_order'] as num?)?.toInt() ?? 0,
      version: (j['version'] as num?)?.toInt() ?? 1,
      updatedAt: _time(j['updated_at']),
      archivedAt: _time(j['archived_at']),
      counts: counts is List ? [for (final c in counts) (c as num).toInt()] : const [0, 0, 0],
    );
  }
}

class CourseMapUnit {
  const CourseMapUnit({required this.id, required this.depth, required this.name, this.parentId, this.sortOrder = 0});

  final String id;
  final String? parentId;
  final int depth;
  final String name;
  final int sortOrder;

  factory CourseMapUnit.fromJson(Map<String, dynamic> j) => CourseMapUnit(
        id: j['id'] as String,
        parentId: j['parent_id'] as String?,
        depth: (j['depth'] as num).toInt(),
        name: (j['name'] ?? '') as String,
        sortOrder: (j['sort_order'] as num?)?.toInt() ?? 0,
      );
}

/// 보관한 단원 묶음의 맨 위. [count]는 함께 보관된 아래 단원까지 센 수.
class CourseMapArchivedUnit {
  const CourseMapArchivedUnit({
    required this.id,
    required this.depth,
    required this.name,
    required this.count,
    this.parentId,
    this.archivedAt,
    this.parentActive = true,
    this.path = const [],
  });

  final String id;
  final String? parentId;
  final int depth;
  final String name;
  final DateTime? archivedAt;
  final bool parentActive;

  /// 위 단원 이름(대단원부터).
  final List<String> path;
  final int count;

  factory CourseMapArchivedUnit.fromJson(Map<String, dynamic> j) => CourseMapArchivedUnit(
        id: j['id'] as String,
        parentId: j['parent_id'] as String?,
        depth: (j['depth'] as num).toInt(),
        name: (j['name'] ?? '') as String,
        archivedAt: _time(j['archived_at']),
        parentActive: j['parent_active'] != false,
        path: [for (final p in (j['path'] as List? ?? const [])) p.toString()],
        count: (j['count'] as num?)?.toInt() ?? 1,
      );
}

class CourseMapDetail {
  const CourseMapDetail({required this.course, required this.units, this.archived = const []});

  final CourseMapCourse course;

  /// 위에서 아래로 늘어놓은 살아 있는 단원(대단원 → 그 중단원 → 그 소단원 …).
  final List<CourseMapUnit> units;
  final List<CourseMapArchivedUnit> archived;

  factory CourseMapDetail.fromJson(Map<String, dynamic> j) => CourseMapDetail(
        course: CourseMapCourse.fromJson(Map<String, dynamic>.from(j['course'] as Map)),
        units: [for (final u in (j['units'] as List? ?? const [])) CourseMapUnit.fromJson(Map<String, dynamic>.from(u as Map))],
        archived: [
          for (final u in (j['archived'] as List? ?? const []))
            CourseMapArchivedUnit.fromJson(Map<String, dynamic>.from(u as Map))
        ],
      );
}

/// 저장할 단원 한 줄. 목록 순서가 같은 부모 안 순서다.
class CourseMapUnitInput {
  const CourseMapUnitInput({required this.id, required this.name, this.parentId});

  final String id;
  final String? parentId;
  final String name;

  Map<String, dynamic> toJson() => {'id': id, 'parent_id': parentId, 'name': name};
}

/// 단원에 놓인 개념 한 줄(개념 등장 위치 중 기준 단원에 이어진 줄). [origin]이 ai면 Think 카드 승인으로 놓였다.
class CourseMapPlacement {
  const CourseMapPlacement({
    required this.id,
    required this.unitId,
    required this.conceptId,
    required this.name,
    this.sort = 0,
    this.origin = 'owner',
    this.note,
    this.type,
    this.subType,
    this.sources = 0,
    this.statementId,
    this.createdAt,
  });

  final String id;
  final String unitId;
  final String conceptId;
  final String name;
  final int sort;
  final String origin;

  /// Think가 놓았으면 그때 근거.
  final String? note;

  /// 개념 유형 이름. 유형을 고르지 않은 개념은 null.
  final String? type;
  final String? subType;
  final int sources;
  final String? statementId;
  final DateTime? createdAt;

  bool get byThink => origin == 'ai';

  factory CourseMapPlacement.fromJson(Map<String, dynamic> j) => CourseMapPlacement(
        id: j['id'] as String,
        unitId: j['unit_id'] as String,
        conceptId: j['concept_id'] as String,
        name: (j['name'] ?? '') as String,
        sort: (j['sort'] as num?)?.toInt() ?? 0,
        origin: (j['origin'] ?? 'owner') as String,
        note: j['note'] as String?,
        type: j['type'] as String?,
        subType: j['sub_type'] as String?,
        sources: (j['sources'] as num?)?.toInt() ?? 0,
        statementId: j['statement_id'] as String?,
        createdAt: _time(j['created_at']),
      );
}

/// 전체 개념 수, 살아 있는 과정 단원에 한 번이라도 놓인 개념 수, 과정별 놓인 줄 수.
class CourseMapPlacementOverview {
  const CourseMapPlacementOverview({required this.concepts, required this.placed, this.perCourse = const {}});

  final int concepts;
  final int placed;
  final Map<String, int> perCourse;

  factory CourseMapPlacementOverview.fromJson(Map<String, dynamic> j) => CourseMapPlacementOverview(
        concepts: (j['concepts'] as num?)?.toInt() ?? 0,
        placed: (j['placed'] as num?)?.toInt() ?? 0,
        perCourse: {
          for (final e in Map<String, dynamic>.from(j['courses'] as Map? ?? const {}).entries)
            e.key: (e.value as num).toInt(),
        },
      );
}

/// 최근 변경 한 줄(`course_recent_changes`). [kind]는 placement(배치) · content(개념 본문·이름) · statement(서술 확정).
class CourseChange {
  const CourseChange({
    required this.key,
    required this.at,
    required this.kind,
    required this.conceptId,
    required this.conceptName,
    this.time,
    this.action,
    this.beforeLog = false,
    this.courseName,
    this.path = const [],
    this.fromPath = const [],
    this.origin,
    this.actionId,
    this.note,
    this.beforeName,
    this.afterName,
    this.renamed = false,
    this.contentChanged = false,
    this.via,
    this.role,
    this.title,
    this.version,
  });

  /// 다음 쪽을 읽을 때 서버에 그대로 돌려준다.
  final String key;
  final String at;
  final DateTime? time;
  final String kind;
  final String conceptId;
  final String conceptName;

  /// 배치: add · move · remove.
  final String? action;

  /// 배치 기록을 시작하기 전에 놓인 배치. 놓은 시각과 지금 위치만 안다.
  final bool beforeLog;
  final String? courseName;

  /// 배치: 넣거나 옮긴 단원(대단원부터), 기록 전 배치는 지금 위치.
  final List<String> path;

  /// 배치: 옮기거나 빼기 전 단원.
  final List<String> fromPath;

  /// 배치: owner · ai. 본문: 수정안을 쓴 쪽(owner · ai), 바로 고쳤으면 null.
  final String? origin;
  final String? actionId;
  final String? note;

  /// 본문: 고치기 전 이름과 고친 뒤 이름.
  final String? beforeName;
  final String? afterName;
  final bool renamed;
  final bool contentChanged;

  /// 본문: direct(바로 고침) · draft(수정안 확정).
  final String? via;

  /// 서술: core(공통 내용) · statement.
  final String? role;
  final String? title;
  final int? version;

  bool get byThink => origin == 'ai';

  static List<String> _names(Object? v) => [for (final x in (v as List? ?? const [])) x.toString()];

  factory CourseChange.fromJson(Map<String, dynamic> j) => CourseChange(
        key: j['key'] as String,
        at: j['at'].toString(),
        time: _time(j['at']),
        kind: (j['kind'] ?? '') as String,
        conceptId: (j['concept_id'] ?? '') as String,
        conceptName: (j['concept_name'] ?? '') as String,
        action: j['action'] as String?,
        beforeLog: j['before_log'] == true,
        courseName: j['course_name'] as String?,
        path: _names(j['path']),
        fromPath: _names(j['from_path']),
        origin: j['origin'] as String?,
        actionId: j['action_id'] as String?,
        note: j['note'] as String?,
        beforeName: j['before_name'] as String?,
        afterName: j['after_name'] as String?,
        renamed: j['renamed'] == true,
        contentChanged: j['content_changed'] == true,
        via: j['via'] as String?,
        role: j['role'] as String?,
        title: j['title'] as String?,
        version: (j['version'] as num?)?.toInt(),
      );
}

class CourseChangePage {
  const CourseChangePage({required this.items, required this.more});

  final List<CourseChange> items;

  /// 더 오래된 변경이 남아 있다.
  final bool more;

  factory CourseChangePage.fromJson(Map<String, dynamic> j) => CourseChangePage(
        items: [
          for (final r in (j['items'] as List? ?? const [])) CourseChange.fromJson(Map<String, dynamic>.from(r as Map))
        ],
        more: j['more'] == true,
      );
}

const String kCourseChangePlacement = 'placement';
const String kCourseChangeContent = 'content';
const String kCourseChangeStatement = 'statement';

/// 개념 넣기 창의 찾기 결과.
class CourseMapConceptHit {
  const CourseMapConceptHit({required this.id, required this.name});

  final String id;
  final String name;
}

/// 교육과정 코드(개념 등장 위치와 같은 값).
const Map<String, String> kCourseMapCurricula = {
  'rev_2022': '2022 개정',
  'rev_2015': '2015 개정',
  'rev_2009': '2009 개정',
  'k7_2007': '2007 개정',
  'k7_1997': '7차',
  'legacy_1to6': '1~6차',
};

const List<String> kCourseMapSchoolLevels = ['초', '중', '고'];

class CourseMapException implements Exception {
  CourseMapException(this.code, this.message);

  final String code;
  final String message;

  bool get notReady => code == 'not_ready';
  bool get stale => code == 'course_map_stale' || code == 'course_map_list_stale';

  static const Map<String, String> _messages = {
    'course_map_forbidden': '최고 관리자만 과정 탐색도를 보고 고칠 수 있습니다.',
    'course_map_not_found': '이 과정을 찾을 수 없습니다(보관됐거나 지워졌을 수 있습니다).',
    'course_map_stale': '그사이 이 과정이 다른 곳에서 저장됐습니다. 지금 편집은 그대로 남아 있습니다. '
        '최신 저장본을 불러오면 지금 편집은 버려집니다.',
    'course_map_archived': '보관한 과정입니다. 되살린 뒤에 고칠 수 있습니다.',
    'course_map_bad_name': '이름은 비울 수 없고, 과정 이름은 40자·단원 이름은 80자까지입니다.',
    'course_map_bad_level': '학교급은 초·중·고 중 하나여야 합니다.',
    'course_map_bad_curriculum': '알 수 없는 교육과정 코드입니다.',
    'course_map_bad_units': '저장할 단원 목록이 올바르지 않습니다(같은 단원이 두 번 들어감 등).',
    'course_map_too_many': '한 과정에는 단원을 3,000개까지 둘 수 있습니다.',
    'course_map_unit_foreign': '다른 과정의 단원은 이 과정으로 옮길 수 없습니다.',
    'course_map_unit_archived': '보관한 단원이 들어 있습니다. 보관한 단원은 되살리기로만 돌아옵니다.',
    'course_map_unit_not_found': '보관하거나 되살릴 단원을 찾지 못했습니다.',
    'course_map_unit_conflict': '보관할 단원이 저장 목록에도 들어 있습니다.',
    'course_map_unit_missing': '저장 목록에서 빠진 단원이 있습니다. 최신 저장본을 불러와 다시 해 주세요.',
    'course_map_bad_parent': '위 단원이 저장 목록에 없거나 맞지 않습니다.',
    'course_map_cycle': '단원을 자기 아래로 옮길 수 없습니다.',
    'course_map_too_deep': '대·중·소 세 단계까지만 둘 수 있습니다.',
    'course_map_parent_archived': '위 단원이 보관돼 있습니다. 위 단원을 먼저 되살리세요.',
    'course_map_list_stale': '그사이 과정 목록이 바뀌었습니다. 목록을 다시 불러온 뒤 해 주세요.',
    'course_map_bad_order': '과정 순서가 올바르지 않습니다.',
    'course_placement_use_rpc': '단원에 놓인 개념은 과정 탐색도에서만 바꿀 수 있습니다.',
    'course_placement_unit_not_found': '단원을 찾지 못했습니다(보관했거나 아직 저장하지 않은 단원일 수 있습니다).',
    'course_placement_unit_foreign': '다른 과정의 단원입니다.',
    'course_placement_not_found': '그 개념 배치를 찾지 못했습니다. 다시 읽어 주세요.',
    'course_placement_concept_not_found': '개념을 찾지 못했습니다(지워졌을 수 있습니다).',
    'course_placement_exists': '이미 그 단원에 놓인 개념입니다.',
    'course_placement_same_unit': '이미 그 단원에 있습니다.',
    'course_placement_stale': '그사이 이 단원의 개념 목록이 바뀌었습니다. 다시 읽은 뒤 해 주세요.',
    'course_placement_bad_concepts': '넣을 개념을 1~100개 골라 주세요.',
    'course_changes_bad_kinds': '알 수 없는 변경 종류입니다.',
  };

  static final RegExp _code = RegExp(r'course_(?:map|placement|changes)_[a-z_]+');

  static CourseMapException from(Object e) {
    if (e is CourseMapException) return e;
    if (e is PostgrestException) {
      final code = e.code ?? '';
      final found = _code.firstMatch(e.message)?.group(0);
      if (found != null && _messages.containsKey(found)) return CourseMapException(found, _messages[found]!);
      if (code == '42P01' || code == 'PGRST205' || code == '42883' || code == 'PGRST202') {
        return CourseMapException('not_ready', 'DB에 과정 탐색도 저장소가 아직 없습니다. 마이그레이션을 반영한 뒤 쓸 수 있습니다.');
      }
      if (code == '42501') return CourseMapException('denied', '이 계정으로는 할 수 없는 작업입니다.');
      return CourseMapException(code.isEmpty ? 'error' : code, e.message);
    }
    return CourseMapException('error', e.toString());
  }

  @override
  String toString() => message;
}

abstract class CourseMapBackend {
  Future<List<CourseMapCourse>> list();
  Future<CourseMapDetail> get(String courseId);
  Future<CourseMapDetail> create({required String name, required String schoolLevel, String? curriculumCode});

  /// [units]는 살아 있을 단원 전부(위에서 아래 순서), [archive]는 이번에 보관할 저장된 단원 전부.
  Future<CourseMapDetail> save({
    required CourseMapCourse base,
    required String name,
    required String schoolLevel,
    required String? curriculumCode,
    required List<CourseMapUnitInput> units,
    required List<String> archive,
  });
  Future<CourseMapDetail> restoreUnit({required CourseMapCourse base, required String unitId});
  Future<List<CourseMapCourse>> archiveCourse(CourseMapCourse base);
  Future<List<CourseMapCourse>> restoreCourse(String courseId);
  Future<List<CourseMapCourse>> reorder({required List<String> expected, required List<String> ids});

  /// 과정의 살아 있는 단원에 놓인 개념 전부(단원 → 단원 안 순서). 바꾸기 RPC도 같은 목록을 돌려준다.
  Future<List<CourseMapPlacement>> placements(String courseId);
  Future<CourseMapPlacementOverview> placementOverview();
  Future<List<CourseMapPlacement>> addPlacements({required String unitId, required List<String> conceptIds});
  Future<List<CourseMapPlacement>> removePlacement(String placementId);
  Future<List<CourseMapPlacement>> movePlacement({required String placementId, required String unitId});

  /// [ids]는 그 단원에 지금 놓인 줄 전부를 새 순서로.
  Future<List<CourseMapPlacement>> reorderPlacements({required String unitId, required List<String> ids});
  Future<List<CourseMapConceptHit>> searchConcepts(String query);

  /// 배치 기록·본문 고친 기록·서술 확정 기록을 새것부터. [olderThan]을 주면 그보다 오래된 것부터 읽는다.
  Future<CourseChangePage> recentChanges({List<String>? kinds, CourseChange? olderThan, int limit = 60});
}

class SupabaseCourseMapBackend implements CourseMapBackend {
  SupabaseCourseMapBackend(this._db);

  final SupabaseClient _db;

  Future<T> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } catch (e) {
      throw CourseMapException.from(e);
    }
  }

  static List<CourseMapCourse> _courses(Object? data) =>
      [for (final r in (data as List? ?? const [])) CourseMapCourse.fromJson(Map<String, dynamic>.from(r as Map))];

  static CourseMapDetail _detail(Object? data) => CourseMapDetail.fromJson(Map<String, dynamic>.from(data as Map));

  @override
  Future<List<CourseMapCourse>> list() => _guard(() async => _courses(await _db.rpc('course_maps_list')));

  @override
  Future<CourseMapDetail> get(String courseId) =>
      _guard(() async => _detail(await _db.rpc('course_map_get', params: {'p_course_id': courseId})));

  @override
  Future<CourseMapDetail> create({required String name, required String schoolLevel, String? curriculumCode}) =>
      _guard(() async => _detail(await _db.rpc('course_map_create', params: {
            'p_name': name,
            'p_school_level': schoolLevel,
            'p_curriculum_code': curriculumCode,
          })));

  @override
  Future<CourseMapDetail> save({
    required CourseMapCourse base,
    required String name,
    required String schoolLevel,
    required String? curriculumCode,
    required List<CourseMapUnitInput> units,
    required List<String> archive,
  }) =>
      _guard(() async => _detail(await _db.rpc('course_map_save', params: {
            'p_course_id': base.id,
            'p_version': base.version,
            'p_course': {'name': name, 'school_level': schoolLevel, 'curriculum_code': curriculumCode},
            'p_units': [for (final u in units) u.toJson()],
            'p_archive': archive,
          })));

  @override
  Future<CourseMapDetail> restoreUnit({required CourseMapCourse base, required String unitId}) =>
      _guard(() async => _detail(await _db.rpc('course_map_unit_restore', params: {
            'p_course_id': base.id,
            'p_version': base.version,
            'p_unit_id': unitId,
          })));

  @override
  Future<List<CourseMapCourse>> archiveCourse(CourseMapCourse base) => _guard(() async =>
      _courses(await _db.rpc('course_map_archive', params: {'p_course_id': base.id, 'p_version': base.version})));

  @override
  Future<List<CourseMapCourse>> restoreCourse(String courseId) =>
      _guard(() async => _courses(await _db.rpc('course_map_restore', params: {'p_course_id': courseId})));

  @override
  Future<List<CourseMapCourse>> reorder({required List<String> expected, required List<String> ids}) => _guard(
      () async => _courses(await _db.rpc('course_maps_reorder', params: {'p_expected': expected, 'p_ids': ids})));

  static List<CourseMapPlacement> _placements(Object? data) =>
      [for (final r in (data as List? ?? const [])) CourseMapPlacement.fromJson(Map<String, dynamic>.from(r as Map))];

  @override
  Future<List<CourseMapPlacement>> placements(String courseId) =>
      _guard(() async => _placements(await _db.rpc('course_map_placements', params: {'p_course_id': courseId})));

  @override
  Future<CourseMapPlacementOverview> placementOverview() => _guard(() async => CourseMapPlacementOverview.fromJson(
      Map<String, dynamic>.from(await _db.rpc('concept_placement_overview') as Map)));

  @override
  Future<List<CourseMapPlacement>> addPlacements({required String unitId, required List<String> conceptIds}) =>
      _guard(() async => _placements(
          await _db.rpc('course_placement_add', params: {'p_unit_id': unitId, 'p_concept_ids': conceptIds})));

  @override
  Future<List<CourseMapPlacement>> removePlacement(String placementId) =>
      _guard(() async => _placements(await _db.rpc('course_placement_remove', params: {'p_id': placementId})));

  @override
  Future<List<CourseMapPlacement>> movePlacement({required String placementId, required String unitId}) =>
      _guard(() async =>
          _placements(await _db.rpc('course_placement_move', params: {'p_id': placementId, 'p_unit_id': unitId})));

  @override
  Future<List<CourseMapPlacement>> reorderPlacements({required String unitId, required List<String> ids}) =>
      _guard(() async =>
          _placements(await _db.rpc('course_placement_reorder', params: {'p_unit_id': unitId, 'p_ids': ids})));

  @override
  Future<List<CourseMapConceptHit>> searchConcepts(String query) => _guard(() async {
        final q = query.trim().replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');
        final rows = await _db.from('concepts').select('id,name').ilike('name', '%$q%').order('name').limit(30);
        return [for (final r in rows) CourseMapConceptHit(id: r['id'] as String, name: (r['name'] ?? '') as String)];
      });

  @override
  Future<CourseChangePage> recentChanges({List<String>? kinds, CourseChange? olderThan, int limit = 60}) =>
      _guard(() async => CourseChangePage.fromJson(Map<String, dynamic>.from(await _db.rpc('course_recent_changes', params: {
            'p_kinds': kinds,
            'p_before_at': olderThan?.at,
            'p_before_key': olderThan?.key,
            'p_limit': limit,
          }) as Map)));
}
