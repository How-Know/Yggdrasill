import 'package:supabase_flutter/supabase_flutter.dart';

import 'concept_book_order.dart';

/// 개념 사이 관계(여섯 유형)와 "같은 개념인지 검토 필요" 표시.
/// 설계: docs/architecture/concept-library.md §4.2, "관계 유형"
///
/// 운영자가 고른 것만 저장한다. 이름·학년·문장이 비슷하다고 관계를 넣거나 개념을 합치지 않는다.
/// 쓰기는 RPC로만 한다. "같은 개념"으로 판단해도 두 개념은 그대로 두고 판단만 기록한다.
/// 모든 관계는 "[conceptId](출발) → [relatedId](기준)"로 읽는다.
enum ConceptRelationKind { kindOf, partOf, derivedFrom, dependsOn, extendsOf, specialCase }

extension ConceptRelationKindX on ConceptRelationKind {
  String get db => switch (this) {
        ConceptRelationKind.kindOf => 'kind_of',
        ConceptRelationKind.partOf => 'part_of',
        ConceptRelationKind.derivedFrom => 'derived_from',
        ConceptRelationKind.dependsOn => 'depends_on',
        ConceptRelationKind.extendsOf => 'extends',
        ConceptRelationKind.specialCase => 'special_case',
      };

  String get label => switch (this) {
        ConceptRelationKind.kindOf => '종류·특수화',
        ConceptRelationKind.partOf => '구성·부분',
        ConceptRelationKind.derivedFrom => '근거·유도',
        ConceptRelationKind.dependsOn => '학습 의존',
        ConceptRelationKind.extendsOf => '확장',
        ConceptRelationKind.specialCase => '특수한 경우',
      };

  /// 근거·유도는 어떤 유도인지, 학습 의존은 어떤 목표·방법인지 맥락이 있어야 한다.
  bool get contextRequired => this == ConceptRelationKind.derivedFrom || this == ConceptRelationKind.dependsOn;

  /// "[a](출발) → [b](기준)"로 읽는 문장. 맥락이 있으면 그 맥락 안에서만 성립한다고 적는다.
  String sentence(String a, String b, [String? context]) {
    final c = (context ?? '').trim();
    final tail = c.isEmpty ? '' : ' · 맥락: $c';
    return switch (this) {
      ConceptRelationKind.kindOf => '"$a"은(는) "$b"의 한 종류$tail',
      ConceptRelationKind.partOf => '"$a"은(는) "$b"을(를) 이루는 요소$tail',
      ConceptRelationKind.derivedFrom =>
        '"$a"은(는) "$b"을(를) 근거로 유도·증명됨${c.isEmpty ? ' (맥락 기록 없음)' : ' · $c'}',
      ConceptRelationKind.dependsOn => c.isEmpty
          ? '"$a"을(를) 배울 때 "$b"이(가) 필요한 맥락이 기록되지 않음'
          : '맥락 "$c"에서: "$a"을(를) 배우거나 쓰려면 "$b"이(가) 필요',
      ConceptRelationKind.extendsOf => '"$a"은(는) "$b"을(를) 넓힌 개념$tail',
      ConceptRelationKind.specialCase => '"$a"은(는) "$b"의 특수한 경우$tail',
    };
  }

  static ConceptRelationKind? fromDb(String? v) => switch (v) {
        'kind_of' => ConceptRelationKind.kindOf,
        'part_of' => ConceptRelationKind.partOf,
        'derived_from' => ConceptRelationKind.derivedFrom,
        'depends_on' => ConceptRelationKind.dependsOn,
        'extends' => ConceptRelationKind.extendsOf,
        'special_case' => ConceptRelationKind.specialCase,
        _ => null,
      };
}

/// 관계를 누가 어떻게 정했는지. 이 기능 전에 생긴 관계는 기록이 없다([ConceptRelation.decision]이 null).
class ConceptRelationDecision {
  const ConceptRelationDecision({required this.via, this.at, this.actionId});

  /// draft · review · manual · think
  final String via;
  final DateTime? at;

  /// Think 카드로 정했으면 그 카드 id.
  final String? actionId;

  String get label => switch (via) {
        'draft' => '초안 확정에서 운영자가 고름',
        'review' => '같은 개념 검토에서 운영자가 판단',
        'think' => 'Think 카드를 운영자가 승인',
        _ => '운영자가 직접 저장',
      };
}

/// 관계 이력 한 줄(넣기·바꾸기·빼기). 그때의 개념 이름을 함께 적어 개념이 지워져도 읽힌다.
class ConceptRelationEvent {
  const ConceptRelationEvent({
    required this.event,
    required this.relationId,
    required this.conceptName,
    required this.relatedName,
    required this.via,
    this.kind,
    this.context,
    this.reason,
    this.at,
  });

  /// add · change · remove
  final String event;
  final String relationId;
  final String conceptName;
  final String relatedName;
  final String via;

  /// 바뀐 뒤(빼기면 빼기 전) 유형·맥락.
  final ConceptRelationKind? kind;
  final String? context;
  final String? reason;
  final DateTime? at;

  String get eventLabel => switch (event) {
        'add' => '넣음',
        'remove' => '뺌',
        _ => '고침',
      };

  factory ConceptRelationEvent.fromRow(Map<String, dynamic> r) {
    final state = Map<String, dynamic>.from((r['after'] ?? r['before'] ?? const {}) as Map);
    return ConceptRelationEvent(
      event: r['event'] as String? ?? 'change',
      relationId: r['relation_id']?.toString() ?? '',
      conceptName: r['concept_name'] as String? ?? '(이름 모름)',
      relatedName: r['related_name'] as String? ?? '(이름 모름)',
      via: r['via'] as String? ?? 'manual',
      kind: ConceptRelationKindX.fromDb(state['kind'] as String?),
      context: state['context'] as String?,
      reason: r['reason'] as String?,
      at: DateTime.tryParse(r['at']?.toString() ?? '')?.toLocal(),
    );
  }
}

/// 개념 하나의 관계와 최근 관계 이력.
class ConceptRelationSheet {
  const ConceptRelationSheet({
    required this.relations,
    this.events = const [],
    this.eventCount = 0,
    this.pendingAdds = 0,
  });

  final List<ConceptRelation> relations;

  /// 최근 것부터 최대 20개. 전체 수는 [eventCount].
  final List<ConceptRelationEvent> events;
  final int eventCount;

  /// 이 개념에 관계를 새로 넣자는, 승인을 기다리는 Think 카드 항목 수.
  final int pendingAdds;
}

/// concept_relation_list 결과를 읽는다.
ConceptRelationSheet conceptRelationSheetFromJson(Map<String, dynamic> data) {
  final pendingByRelation = <String, int>{};
  var pendingAdds = 0;
  for (final p in (data['pending'] as List? ?? const [])) {
    final id = (p as Map)['relation_id']?.toString();
    if (id == null || id.isEmpty) {
      pendingAdds++;
    } else {
      pendingByRelation[id] = (pendingByRelation[id] ?? 0) + 1;
    }
  }
  return ConceptRelationSheet(
    relations: [
      for (final r in (data['relations'] as List? ?? const []))
        if (ConceptRelation.fromRow(Map<String, dynamic>.from(r as Map),
                pendingCards: pendingByRelation[(r)['id']?.toString()] ?? 0)
            case final rel?)
          rel
    ],
    events: [
      for (final e in (data['events'] as List? ?? const []))
        ConceptRelationEvent.fromRow(Map<String, dynamic>.from(e as Map))
    ],
    eventCount: (data['event_count'] as num?)?.toInt() ?? 0,
    pendingAdds: pendingAdds,
  );
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

/// 개념(출발) → 기준 개념. [kind] 문장은 [ConceptRelationKindX.sentence]로 읽는다.
class ConceptRelation {
  const ConceptRelation({
    required this.id,
    required this.conceptId,
    required this.relatedId,
    required this.kind,
    required this.origin,
    this.note,
    this.createdAt,
    this.context,
    this.basis,
    this.rev,
    this.decision,
    this.rereview,
    this.pendingCards = 0,
  });

  final String id;
  final String conceptId;
  final String relatedId;
  final ConceptRelationKind kind;

  /// 어디서 생겼는지: draft(초안 확정 때 고름) · review(검토 필요를 판단하며) · manual(상세에서 직접) · think(Think 카드).
  /// 누가 정했는지([decision])와 다르다.
  final String origin;
  final String? note;
  final DateTime? createdAt;
  final String? context;
  final String? basis;

  /// 고칠 때마다 오른다. 읽은 판이 지금과 다르면 저장·빼기가 막힌다. 관계 유형 마이그레이션 전 DB면 null.
  final int? rev;
  final ConceptRelationDecision? decision;

  /// 판단 뒤 두 개념 중 하나의 글(이름·본문·확정 서술)이 바뀌었으면 true. 판단 때 기록이 없으면 null(모름).
  final bool? rereview;

  /// 이 관계를 고치거나 빼자는, 승인을 기다리는 Think 카드 항목 수.
  final int pendingCards;

  String get originLabel => switch (origin) {
        'draft' => '초안 확정 때 생김',
        'review' => '검토하며 생김',
        'think' => 'Think 카드 승인으로 생김',
        _ => '직접 넣음',
      };

  String get decisionLabel => decision?.label ?? '결정 기록 없음(이 기능 전에 생긴 관계)';

  /// 이 관계에서 [conceptId] 쪽이 아닌 개념.
  String otherOf(String id) => id == conceptId ? relatedId : conceptId;

  /// 표의 한 줄(concept_id·related_id)이나 concept_relation_list 의 한 줄(from·to·decision·rereview).
  static ConceptRelation? fromRow(Map<String, dynamic> r, {int pendingCards = 0}) {
    final kind = ConceptRelationKindX.fromDb(r['kind'] as String?);
    if (kind == null) return null;
    final from = r['from'] is Map ? Map<String, dynamic>.from(r['from'] as Map) : null;
    final to = r['to'] is Map ? Map<String, dynamic>.from(r['to'] as Map) : null;
    final d = r['decision'] is Map ? Map<String, dynamic>.from(r['decision'] as Map) : null;
    return ConceptRelation(
      id: r['id'] as String,
      conceptId: (r['concept_id'] ?? from?['id']) as String,
      relatedId: (r['related_id'] ?? to?['id']) as String,
      kind: kind,
      origin: r['origin'] as String? ?? 'manual',
      note: r['note'] as String?,
      createdAt: DateTime.tryParse(r['created_at']?.toString() ?? '')?.toLocal(),
      context: r['context'] as String?,
      basis: r['basis'] as String?,
      rev: (r['rev'] as num?)?.toInt(),
      decision: d == null || d['recorded'] != true
          ? null
          : ConceptRelationDecision(
              via: d['via'] as String? ?? 'manual',
              at: DateTime.tryParse(d['at']?.toString() ?? '')?.toLocal(),
              actionId: d['action_id'] as String?,
            ),
      rereview: r['rereview'] as bool?,
      pendingCards: pendingCards,
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
    'concept_relation_too_long': '글이 너무 깁니다(맥락 300자, 근거 1000자, 메모 500자).',
    'concept_relation_not_found': '개념이나 관계를 찾을 수 없습니다(지워졌을 수 있습니다).',
    'concept_relation_reverse_exists':
        '반대 방향 관계가 이미 있습니다. 서로가 서로의 한 종류·요소로 보이면 같은 개념인지 먼저 검토하세요.',
    'concept_relation_exists': '같은 방향·유형·맥락의 관계가 이미 있습니다. 있는 관계를 고치세요.',
    'concept_relation_context_required': '근거·유도와 학습 의존은 맥락(어떤 유도인지, 어떤 목표·방법인지)을 적어야 합니다.',
    'concept_relation_stale': '읽은 뒤 이 관계가 바뀌었습니다. 다시 읽은 뒤 고치세요.',
    'concept_relation_unchanged': '바뀐 것이 없습니다.',
    'concept_relation_rev_required': '관계를 다시 읽은 뒤 고치세요.',
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
  /// 이 개념에서 나가거나 들어오는 관계와 최근 관계 이력.
  Future<ConceptRelationSheet> relationsFor(String conceptId);

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

  /// 확장·특수한 경우를 넣는다. 같은 방향 줄이 있으면 그 줄의 종류를 바꾼다(옛 동작).
  Future<ConceptRelation> setRelation({
    required String conceptId,
    required String relatedId,
    required ConceptRelationKind kind,
    String? note,
  });

  /// [id]가 null이면 새로 넣고, 있으면 [rev](읽은 판)가 지금과 같을 때만 고친다. 같은 관계가 이미 있으면 막는다.
  Future<ConceptRelation> saveRelation({
    String? id,
    int? rev,
    required String conceptId,
    required String relatedId,
    required ConceptRelationKind kind,
    String? context,
    String? basis,
    String? note,
  });

  /// 관계만 뺀다. [rev]를 주면 읽은 판이 지금과 같을 때만.
  Future<void> removeRelation(String id, {int? rev});
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

  static const _listMissing = {'42883', 'PGRST202'};

  @override
  Future<ConceptRelationSheet> relationsFor(String conceptId) => _guard(() async {
        final Object? data;
        try {
          data = await _db.rpc('concept_relation_list', params: {'p_concept': conceptId});
        } on PostgrestException catch (e) {
          if (!_listMissing.contains(e.code)) rethrow;
          // 관계 유형 마이그레이션 전 DB: 표를 그대로 읽는다(맥락·결정 기록 칸이 아직 없다).
          final rows = await _db
              .from('concept_relations')
              .select(_relationColumns)
              .or('concept_id.eq.$conceptId,related_id.eq.$conceptId')
              .order('created_at', ascending: true);
          return ConceptRelationSheet(relations: [
            for (final r in rows as List)
              if (ConceptRelation.fromRow(Map<String, dynamic>.from(r as Map)) case final rel?) rel
          ]);
        }
        return conceptRelationSheetFromJson(Map<String, dynamic>.from(data as Map));
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
  Future<ConceptRelation> saveRelation({
    String? id,
    int? rev,
    required String conceptId,
    required String relatedId,
    required ConceptRelationKind kind,
    String? context,
    String? basis,
    String? note,
  }) =>
      _guard(() async {
        final data = await _db.rpc('concept_relation_save', params: {
          'p_id': id,
          'p_rev': rev,
          'p_concept': conceptId,
          'p_related': relatedId,
          'p_kind': kind.db,
          'p_context': _note(context),
          'p_basis': _note(basis),
          'p_note': _note(note),
        });
        return ConceptRelation.fromRow(Map<String, dynamic>.from(data as Map))!;
      });

  @override
  Future<void> removeRelation(String id, {int? rev}) => _guard(() => _db.rpc('concept_relation_remove', params: {
        'p_id': id,
        if (rev != null) 'p_rev': rev,
      }));

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
