import 'package:supabase_flutter/supabase_flutter.dart';

import 'concept_book_order.dart';

/// 개념 사이 관계(확장·특수한 경우)와 "같은 개념인지 검토 필요" 표시.
/// 설계: docs/architecture/concept-library.md §4.2
///
/// 운영자가 고른 것만 저장한다. 이름·학년·문장이 비슷하다고 관계를 넣거나 개념을 합치지 않는다.
/// 쓰기는 RPC로만 한다. "같은 개념"으로 판단해도 두 개념은 그대로 두고 판단만 기록한다.
enum ConceptRelationKind { extendsOf, specialCase }

extension ConceptRelationKindX on ConceptRelationKind {
  String get db => this == ConceptRelationKind.extendsOf ? 'extends' : 'special_case';
  String get label => this == ConceptRelationKind.extendsOf ? '확장' : '특수한 경우';

  /// "[a]은(는) [b]…" 로 읽는 문장.
  String sentence(String a, String b) =>
      this == ConceptRelationKind.extendsOf ? '"$a"은(는) "$b"을(를) 넓힌 개념' : '"$a"은(는) "$b"의 특수한 경우';

  static ConceptRelationKind? fromDb(String? v) => switch (v) {
        'extends' => ConceptRelationKind.extendsOf,
        'special_case' => ConceptRelationKind.specialCase,
        _ => null,
      };
}

/// 검토 필요를 닫을 때 고르는 판단.
enum ConceptReviewResolution { different, same, extendsOf, specialCase }

extension ConceptReviewResolutionX on ConceptReviewResolution {
  String get db => switch (this) {
        ConceptReviewResolution.different => 'different',
        ConceptReviewResolution.same => 'same',
        ConceptReviewResolution.extendsOf => 'extends',
        ConceptReviewResolution.specialCase => 'special_case',
      };

  String get label => switch (this) {
        ConceptReviewResolution.different => '서로 다른 개념',
        ConceptReviewResolution.same => '같은 개념(합치지 않고 판단만 기록)',
        ConceptReviewResolution.extendsOf => '확장',
        ConceptReviewResolution.specialCase => '특수한 경우',
      };

  /// 상대 개념이 있어야 하는 판단.
  bool get needsOther => this != ConceptReviewResolution.different;

  /// "[a]"와 "[b]"를 넣은 설명.
  String sentence(String a, String b) => switch (this) {
        ConceptReviewResolution.different => '"$a"와(과) "$b"은(는) 서로 다른 개념',
        ConceptReviewResolution.same => '"$a"와(과) "$b"은(는) 같은 개념 · 합치거나 옮기지 않음',
        ConceptReviewResolution.extendsOf => ConceptRelationKind.extendsOf.sentence(a, b),
        ConceptReviewResolution.specialCase => ConceptRelationKind.specialCase.sentence(a, b),
      };

  static ConceptReviewResolution? fromDb(String? v) => switch (v) {
        'different' => ConceptReviewResolution.different,
        'same' => ConceptReviewResolution.same,
        'extends' => ConceptReviewResolution.extendsOf,
        'special_case' => ConceptReviewResolution.specialCase,
        _ => null,
      };
}

/// 개념 → 기준 개념. [kind]는 "[conceptId]가 [relatedId]를 넓힘 / [relatedId]의 특수한 경우".
class ConceptRelation {
  const ConceptRelation({
    required this.id,
    required this.conceptId,
    required this.relatedId,
    required this.kind,
    required this.origin,
    this.note,
    this.createdAt,
  });

  final String id;
  final String conceptId;
  final String relatedId;
  final ConceptRelationKind kind;

  /// draft(초안 확정 때 고름) · review(검토 필요를 판단하며) · manual(상세에서 직접).
  final String origin;
  final String? note;
  final DateTime? createdAt;

  String get originLabel => switch (origin) {
        'draft' => '초안 확정 때 고름',
        'review' => '검토하며 고름',
        _ => '직접 넣음',
      };

  /// 이 관계에서 [conceptId] 쪽이 아닌 개념.
  String otherOf(String id) => id == conceptId ? relatedId : conceptId;

  static ConceptRelation? fromRow(Map<String, dynamic> r) {
    final kind = ConceptRelationKindX.fromDb(r['kind'] as String?);
    if (kind == null) return null;
    return ConceptRelation(
      id: r['id'] as String,
      conceptId: r['concept_id'] as String,
      relatedId: r['related_id'] as String,
      kind: kind,
      origin: r['origin'] as String? ?? 'manual',
      note: r['note'] as String?,
      createdAt: DateTime.tryParse(r['created_at']?.toString() ?? '')?.toLocal(),
    );
  }
}

class ConceptReview {
  const ConceptReview({
    required this.id,
    required this.conceptId,
    required this.reason,
    required this.open,
    this.otherId,
    this.note,
    this.resolution,
    this.resolutionNote,
    this.createdAt,
    this.resolvedAt,
  });

  final String id;

  /// 검토 필요로 표시된 개념.
  final String conceptId;

  /// 비교할 개념. 없으면 판단할 때 고른다.
  final String? otherId;

  /// same_name · overlap · draft · manual
  final String reason;
  final String? note;
  final bool open;
  final ConceptReviewResolution? resolution;
  final String? resolutionNote;
  final DateTime? createdAt;
  final DateTime? resolvedAt;

  String get reasonLabel => switch (reason) {
        'same_name' => '이름이 같은 개념이 이미 있음',
        'overlap' => '폴더 제안 AI가 겹칠 수 있다고 봄',
        'draft' => '초안 확정 때 검토 필요로 고름',
        _ => '직접 표시',
      };

  factory ConceptReview.fromRow(Map<String, dynamic> r) => ConceptReview(
        id: r['id'] as String,
        conceptId: r['concept_id'] as String,
        otherId: r['other_id'] as String?,
        reason: r['reason'] as String? ?? 'manual',
        note: r['note'] as String?,
        open: r['status'] != 'resolved',
        resolution: ConceptReviewResolutionX.fromDb(r['resolution'] as String?),
        resolutionNote: r['resolution_note'] as String?,
        createdAt: DateTime.tryParse(r['created_at']?.toString() ?? '')?.toLocal(),
        resolvedAt: DateTime.tryParse(r['resolved_at']?.toString() ?? '')?.toLocal(),
      );
}

/// 고르기·표시용 개념 이름표(본문 없음).
class ConceptPick {
  const ConceptPick({required this.id, required this.name, this.versionLabel, this.folder = const [], this.createdAt});

  final String id;
  final String name;
  final String? versionLabel;

  /// 영역부터의 폴더 경로. 모르면 비어 있다.
  final List<String> folder;
  final DateTime? createdAt;

  String get label {
    final v = (versionLabel ?? '').trim();
    return v.isEmpty ? name : '$name ($v)';
  }

  String get folderLabel => folder.isEmpty ? '(폴더 모름)' : folder.join(' > ');
}

/// 같은 이름을 비교할 때 쓰는 이름 열쇠(앞뒤 공백·대소문자만 무시). 확정 RPC와 같은 규칙이다.
String conceptNameKey(String name) => name.trim().toLowerCase();

class ConceptRelationException implements Exception {
  ConceptRelationException(this.code, this.message);

  final String code;
  final String message;

  bool get notReady => code == 'not_ready';

  static const Map<String, String> _messages = {
    'concept_relation_forbidden': '최고 관리자만 관계·검토를 바꿀 수 있습니다.',
    'concept_relation_bad_kind': '알 수 없는 관계입니다.',
    'concept_relation_bad_request': '같은 개념끼리는 잇지 않습니다. 다른 개념을 고르세요.',
    'concept_relation_too_long': '메모가 너무 깁니다(500자).',
    'concept_relation_not_found': '개념이나 관계를 찾을 수 없습니다(지워졌을 수 있습니다).',
    'concept_relation_reverse_exists': '반대 방향 관계가 이미 있습니다. 그 관계를 먼저 빼세요.',
    'concept_review_bad_resolution': '알 수 없는 판단입니다.',
    'concept_review_not_found': '검토 표시를 찾을 수 없습니다.',
    'concept_review_closed': '이미 판단한 검토입니다. 다시 읽어 주세요.',
    'concept_review_other_required': '비교할 개념을 고르세요.',
  };

  static ConceptRelationException from(Object e) {
    if (e is ConceptRelationException) return e;
    if (e is PostgrestException) {
      final code = e.code ?? '';
      for (final entry in _messages.entries) {
        if (e.message.contains(entry.key)) return ConceptRelationException(entry.key, entry.value);
      }
      if (code == '42P01' ||
          code == '42703' ||
          code == 'PGRST205' ||
          code == 'PGRST204' ||
          code == '42883' ||
          code == 'PGRST202') {
        return ConceptRelationException('not_ready', 'DB에 개념 관계·검토 저장소가 아직 없습니다. 마이그레이션을 반영한 뒤 쓸 수 있습니다.');
      }
      if (code == '42501') return ConceptRelationException('denied', '이 계정으로는 할 수 없는 작업입니다.');
      return ConceptRelationException(code.isEmpty ? 'error' : code, e.message);
    }
    return ConceptRelationException('error', e.toString());
  }

  @override
  String toString() => message;
}

abstract class ConceptRelationBackend {
  /// 이 개념에서 나가거나 들어오는 관계.
  Future<List<ConceptRelation>> relationsFor(String conceptId);

  /// 이 개념이 표시됐거나 비교 상대인 검토(열린 것과 닫힌 것).
  Future<List<ConceptReview>> reviewsFor(String conceptId);

  /// 열린 검토 표시가 붙은 개념 id(트리 표시용).
  Future<Set<String>> openReviewConceptIds();

  /// 두 쪽이 모두 [ids] 안에 있는 검토(같은 이름 검토 창).
  Future<List<ConceptReview>> reviewsAmong(List<String> ids);

  Future<Map<String, ConceptPick>> picks(Iterable<String> ids);
  Future<List<ConceptPick>> search(String query);

  /// 이름이 그대로 같은 라이브러리 개념. 이름 열쇠([conceptNameKey]) → 개념(만든 순).
  Future<Map<String, List<ConceptPick>>> named(Iterable<String> names);

  /// 이름(앞뒤 공백·대소문자 무시)이 같은 개념이 둘 이상인 묶음.
  Future<List<List<ConceptPick>>> sameNameGroups();

  Future<ConceptRelation> setRelation({
    required String conceptId,
    required String relatedId,
    required ConceptRelationKind kind,
    String? note,
  });
  Future<void> removeRelation(String id);
  Future<ConceptReview> openReview({required String conceptId, String? otherId, String? note});

  /// [reverse]면 "비교 개념 → 표시된 개념"으로 적는다(확장·특수한 경우의 방향).
  Future<ConceptReview> resolveReview(
    String id,
    ConceptReviewResolution resolution, {
    String? otherId,
    String? note,
    bool reverse = false,
  });
  Future<ConceptReview> decidePair({
    required String conceptId,
    required String otherId,
    required ConceptReviewResolution resolution,
    String? note,
  });
}

class SupabaseConceptRelationBackend implements ConceptRelationBackend {
  SupabaseConceptRelationBackend(this._db);

  final SupabaseClient _db;

  static const _relationColumns = 'id,concept_id,related_id,kind,origin,note,created_at';
  static const _reviewColumns =
      'id,concept_id,other_id,reason,note,status,resolution,resolution_note,created_at,resolved_at';
  static const _chunk = 150;

  Future<T> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } catch (e) {
      throw ConceptRelationException.from(e);
    }
  }

  static String? _note(String? v) => (v ?? '').trim().isEmpty ? null : v!.trim();

  Map<String, List<String>>? _folders;

  Future<Map<String, List<String>>> _folderPaths() async {
    final hit = _folders;
    if (hit != null) return hit;
    final rows = await _db.from('concept_categories').select('id,name,parent_id').limit(5000);
    return _folders = conceptFolderPaths([for (final r in rows as List) Map<String, dynamic>.from(r as Map)]);
  }

  Future<List<ConceptPick>> _toPicks(List rows) async {
    final folders = await _folderPaths();
    return [
      for (final r in rows)
        ConceptPick(
          id: (r as Map)['id'] as String,
          name: r['name'] as String? ?? '',
          versionLabel: r['version_label'] as String?,
          folder: folders[r['main_category_id']?.toString()] ?? const [],
          createdAt: DateTime.tryParse(r['created_at']?.toString() ?? '')?.toLocal(),
        ),
    ];
  }

  static const _pickColumns = 'id,name,version_label,main_category_id,created_at';

  @override
  Future<List<ConceptRelation>> relationsFor(String conceptId) => _guard(() async {
        final rows = await _db
            .from('concept_relations')
            .select(_relationColumns)
            .or('concept_id.eq.$conceptId,related_id.eq.$conceptId')
            .order('created_at', ascending: true);
        return [
          for (final r in rows as List)
            if (ConceptRelation.fromRow(Map<String, dynamic>.from(r as Map)) case final rel?) rel
        ];
      });

  @override
  Future<List<ConceptReview>> reviewsFor(String conceptId) => _guard(() async {
        final rows = await _db
            .from('concept_reviews')
            .select(_reviewColumns)
            .or('concept_id.eq.$conceptId,other_id.eq.$conceptId')
            .order('created_at', ascending: true);
        return [for (final r in rows as List) ConceptReview.fromRow(Map<String, dynamic>.from(r as Map))];
      });

  @override
  Future<Set<String>> openReviewConceptIds() => _guard(() async {
        final rows = await _db.from('concept_reviews').select('concept_id').eq('status', 'open').limit(5000);
        return {for (final r in rows as List) (r as Map)['concept_id'] as String};
      });

  @override
  Future<List<ConceptReview>> reviewsAmong(List<String> ids) => _guard(() async {
        final out = <ConceptReview>[];
        final all = ids.toSet();
        for (var i = 0; i < ids.length; i += _chunk) {
          final part = ids.sublist(i, (i + _chunk).clamp(0, ids.length));
          final rows = await _db.from('concept_reviews').select(_reviewColumns).inFilter('concept_id', part);
          for (final r in rows as List) {
            final v = ConceptReview.fromRow(Map<String, dynamic>.from(r as Map));
            if (v.otherId != null && all.contains(v.otherId)) out.add(v);
          }
        }
        return out;
      });

  @override
  Future<Map<String, ConceptPick>> picks(Iterable<String> ids) => _guard(() async {
        final list = ids.toSet().toList();
        final out = <String, ConceptPick>{};
        for (var i = 0; i < list.length; i += _chunk) {
          final part = list.sublist(i, (i + _chunk).clamp(0, list.length));
          final rows = await _db.from('concepts').select(_pickColumns).inFilter('id', part);
          for (final p in await _toPicks(rows as List)) {
            out[p.id] = p;
          }
        }
        return out;
      });

  @override
  Future<List<ConceptPick>> search(String query) => _guard(() async {
        final q = query.trim().replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');
        if (q.isEmpty) return const <ConceptPick>[];
        final rows = await _db.from('concepts').select(_pickColumns).ilike('name', '%$q%').order('name').limit(30);
        return _toPicks(rows as List);
      });

  @override
  Future<Map<String, List<ConceptPick>>> named(Iterable<String> names) => _guard(() async {
        final list = {
          for (final n in names)
            if (n.trim().isNotEmpty) n.trim()
        }.toList();
        final out = <String, List<ConceptPick>>{};
        for (var i = 0; i < list.length; i += _chunk) {
          final part = list.sublist(i, (i + _chunk).clamp(0, list.length));
          final rows = await _db.from('concepts').select(_pickColumns).inFilter('name', part).order('created_at');
          for (final p in await _toPicks(rows as List)) {
            (out[conceptNameKey(p.name)] ??= []).add(p);
          }
        }
        return out;
      });

  @override
  Future<List<List<ConceptPick>>> sameNameGroups() => _guard(() async {
        const page = 1000;
        final rows = <dynamic>[];
        for (var from = 0; from < 50000; from += page) {
          final part = await _db
              .from('concepts')
              .select(_pickColumns)
              .order('created_at', ascending: true)
              .order('id', ascending: true)
              .range(from, from + page - 1);
          rows.addAll(part as List);
          if (part.length < page) break;
        }
        final byName = <String, List<ConceptPick>>{};
        for (final p in await _toPicks(rows)) {
          (byName[conceptNameKey(p.name)] ??= []).add(p);
        }
        final groups = [
          for (final g in byName.values)
            if (g.length > 1) g
        ]..sort((a, b) => a.first.name.compareTo(b.first.name));
        return groups;
      });

  @override
  Future<ConceptRelation> setRelation({
    required String conceptId,
    required String relatedId,
    required ConceptRelationKind kind,
    String? note,
  }) =>
      _guard(() async {
        final data = await _db.rpc('concept_relation_set', params: {
          'p_concept': conceptId,
          'p_related': relatedId,
          'p_kind': kind.db,
          'p_note': _note(note),
        });
        return ConceptRelation.fromRow(Map<String, dynamic>.from(data as Map))!;
      });

  @override
  Future<void> removeRelation(String id) => _guard(() => _db.rpc('concept_relation_remove', params: {'p_id': id}));

  @override
  Future<ConceptReview> openReview({required String conceptId, String? otherId, String? note}) =>
      _guard(() async => ConceptReview.fromRow(Map<String, dynamic>.from(await _db.rpc('concept_review_open', params: {
            'p_concept': conceptId,
            'p_other': otherId,
            'p_note': _note(note),
          }) as Map)));

  @override
  Future<ConceptReview> resolveReview(
    String id,
    ConceptReviewResolution resolution, {
    String? otherId,
    String? note,
    bool reverse = false,
  }) =>
      _guard(
          () async => ConceptReview.fromRow(Map<String, dynamic>.from(await _db.rpc('concept_review_resolve', params: {
                'p_id': id,
                'p_resolution': resolution.db,
                'p_other': otherId,
                'p_note': _note(note),
                'p_reverse': reverse,
              }) as Map)));

  @override
  Future<ConceptReview> decidePair({
    required String conceptId,
    required String otherId,
    required ConceptReviewResolution resolution,
    String? note,
  }) =>
      _guard(() async =>
          ConceptReview.fromRow(Map<String, dynamic>.from(await _db.rpc('concept_review_decide_pair', params: {
            'p_concept': conceptId,
            'p_other': otherId,
            'p_resolution': resolution.db,
            'p_note': _note(note),
          }) as Map)));
}
