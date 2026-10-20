import 'package:supabase_flutter/supabase_flutter.dart';

import 'concept_service.dart';

/// 개념 탭의 정리 기준·기준–개념 연결·개념 출처.
/// 설계: docs/architecture/concept-library.md
///
/// 정리 기준은 확정본(title·body·version)과 저장된 초안(draft_*)을 따로 든다. 쓰기는 RPC로만 하고,
/// 화면에 보였던 판(version)과 초안 저장 시각을 함께 보내 그사이 바뀌었으면 막는다(concept_criteria_stale).
class ConceptCriterion {
  const ConceptCriterion({
    required this.id,
    this.sortOrder = 0,
    this.title,
    this.body,
    this.version = 0,
    this.confirmedAt,
    this.draftTitle,
    this.draftBody,
    this.draftOrigin,
    this.draftSavedAtRaw,
  });

  final String id;
  final int sortOrder;

  /// 확정본. 확정한 적 없으면 null.
  final String? title;
  final String? body;
  final int version;
  final DateTime? confirmedAt;

  /// 저장된 초안(논의 중인 변경). 없으면 null.
  final String? draftTitle;
  final String? draftBody;

  /// 'owner'(사용자가 저장) · 'template'(기본 틀에서 만든 뒤 아직 안 고침).
  final String? draftOrigin;

  /// 서버가 준 문자열 그대로(마이크로초까지). RPC 기대값으로 되돌려 보낸다.
  final String? draftSavedAtRaw;

  bool get confirmed => version > 0;
  bool get hasDraft => draftTitle != null;
  bool get templateDraft => hasDraft && draftOrigin == 'template';
  DateTime? get draftSavedAt => DateTime.tryParse(draftSavedAtRaw ?? '')?.toLocal();

  /// 편집을 시작할 저장값: 초안이 있으면 초안, 없으면 확정본.
  String get savedTitle => draftTitle ?? title ?? '';
  String get savedBody => draftBody ?? body ?? '';

  factory ConceptCriterion.fromRow(Map<String, dynamic> r) => ConceptCriterion(
        id: r['id'] as String,
        sortOrder: (r['sort_order'] as num?)?.toInt() ?? 0,
        title: r['title'] as String?,
        body: r['body'] as String?,
        version: (r['version'] as num?)?.toInt() ?? 0,
        confirmedAt: DateTime.tryParse(r['confirmed_at']?.toString() ?? '')?.toLocal(),
        draftTitle: r['draft_title'] as String?,
        draftBody: r['draft_body'] as String?,
        draftOrigin: r['draft_origin'] as String?,
        draftSavedAtRaw: r['draft_saved_at']?.toString(),
      );
}

/// 확정 기록 한 판.
class ConceptCriterionRevision {
  const ConceptCriterionRevision({
    required this.version,
    required this.title,
    required this.body,
    this.note,
    this.confirmedAt,
  });

  final int version;
  final String title;
  final String body;
  final String? note;
  final DateTime? confirmedAt;

  factory ConceptCriterionRevision.fromRow(Map<String, dynamic> r) => ConceptCriterionRevision(
        version: (r['version'] as num?)?.toInt() ?? 0,
        title: r['title'] as String? ?? '',
        body: r['body'] as String? ?? '',
        note: r['note'] as String?,
        confirmedAt: DateTime.tryParse(r['confirmed_at']?.toString() ?? '')?.toLocal(),
      );
}

/// 기준에 사용자가 이은 개념(이름·종류만).
class ConceptLinkedConcept {
  const ConceptLinkedConcept({required this.conceptId, required this.name, this.kind});

  final String conceptId;
  final String name;
  final ConceptKind? kind;
}

/// 개념에 사용자가 이은 교재 쪽. 책 이름은 볼 수 있을 때만 있다(추정하지 않는다).
class ConceptSourceRef {
  const ConceptSourceRef({
    required this.id,
    required this.conceptId,
    required this.academyId,
    required this.bookId,
    required this.gradeLabel,
    required this.rawPage,
    this.bookName,
    this.displayPage,
    this.unitPath = const [],
  });

  final String id;
  final String conceptId;
  final String academyId;
  final String bookId;
  final String gradeLabel;

  /// PDF 쪽(1부터).
  final int rawPage;

  /// 책에 인쇄된 쪽. 모르면 null.
  final int? displayPage;
  final String? bookName;
  final List<String> unitPath;

  String get pageLabel => displayPage != null ? '$displayPage쪽 (PDF $rawPage쪽)' : 'PDF $rawPage쪽';

  factory ConceptSourceRef.fromRow(Map<String, dynamic> r) {
    final book = r['resource_files'];
    return ConceptSourceRef(
      id: r['id'] as String,
      conceptId: r['concept_id'] as String,
      academyId: r['academy_id'] as String,
      bookId: r['book_id'] as String,
      gradeLabel: r['grade_label'] as String? ?? '',
      rawPage: (r['raw_page'] as num?)?.toInt() ?? 0,
      displayPage: (r['display_page'] as num?)?.toInt(),
      bookName: book is Map ? book['name'] as String? : null,
      unitPath: (r['unit_path'] is List ? r['unit_path'] as List : const []).map((e) => e.toString()).toList(),
    );
  }
}

class ConceptLibraryException implements Exception {
  ConceptLibraryException(this.code, this.message);

  final String code;
  final String message;

  /// DB 마이그레이션 전이라 표·함수가 없다.
  bool get notReady => code == 'not_ready';
  bool get stale => code == 'concept_criteria_stale';

  static const Map<String, String> _messages = {
    'concept_criteria_stale': '그사이 이 기준이 바뀌었습니다. 최신 저장본을 다시 불러온 뒤 이어서 고쳐 주세요(지금 입력한 내용은 남아 있습니다).',
    'concept_criteria_not_found': '이 기준을 찾을 수 없습니다(지워졌을 수 있습니다).',
    'concept_criteria_forbidden': '최고 관리자만 정리 기준을 바꿀 수 있습니다.',
    'concept_criteria_title_required': '제목을 입력하세요.',
    'concept_criteria_too_long': '제목은 200자, 본문은 20,000자까지 쓸 수 있습니다.',
    'concept_criteria_no_draft': '저장된 초안이 없습니다.',
    'concept_criteria_bad_origin': '알 수 없는 초안 출처입니다.',
  };

  static ConceptLibraryException from(Object e, {String? duplicate, String? denied}) {
    if (e is ConceptLibraryException) return e;
    if (e is PostgrestException) {
      final code = e.code ?? '';
      final msg = e.message;
      for (final entry in _messages.entries) {
        if (msg.contains(entry.key)) return ConceptLibraryException(entry.key, entry.value);
      }
      if (code == '42P01' || code == 'PGRST205' || code == '42883' || code == 'PGRST202') {
        return ConceptLibraryException('not_ready', 'DB에 정리 기준·연결·출처 저장소가 아직 없습니다. 마이그레이션을 반영한 뒤 쓸 수 있습니다.');
      }
      if (code == '23505') return ConceptLibraryException('duplicate', duplicate ?? '이미 저장되어 있습니다.');
      if (code == '42501') return ConceptLibraryException('denied', denied ?? '이 계정으로는 할 수 없는 작업입니다.');
      return ConceptLibraryException(code.isEmpty ? 'error' : code, msg);
    }
    return ConceptLibraryException('error', e.toString());
  }

  @override
  String toString() => message;
}

/// 화면·시험이 같은 규칙으로 쓰도록 저장소를 감춘다. 시험은 메모리 구현을 쓴다.
abstract class ConceptLibraryBackend {
  Future<List<ConceptCriterion>> listCriteria();
  Future<ConceptCriterion> createCriterion({required String title, required String body, String origin = 'owner'});
  Future<ConceptCriterion> saveDraft(ConceptCriterion base, {required String title, required String body});
  Future<ConceptCriterion> confirm(ConceptCriterion base, {String? note});

  /// 확정한 적 없는 항목은 초안이 전부라 항목째 지워지고 null을 돌려준다.
  Future<ConceptCriterion?> discardDraft(ConceptCriterion base);
  Future<List<ConceptCriterionRevision>> listRevisions(String criterionId);

  Future<List<String>> criterionIdsForConcept(String conceptId);
  Future<List<ConceptLinkedConcept>> conceptsForCriterion(String criterionId);
  Future<void> link({required String criterionId, required String conceptId});
  Future<void> unlink({required String criterionId, required String conceptId});

  Future<List<ConceptSourceRef>> sourcesFor(String conceptId);
  Future<ConceptSourceRef> addSource({
    required String conceptId,
    required String academyId,
    required String bookId,
    required String gradeLabel,
    required int rawPage,
    int? displayPage,
    List<String> unitPath = const [],
  });
  Future<void> removeSource(String id);

  /// 개념 초안을 확정할 때 붙은 개념 유형 이름. 유형이 없는 개념(기존 개념 등)은 null.
  Future<String?> conceptTypeName(String conceptId);
}

class SupabaseConceptLibraryBackend implements ConceptLibraryBackend {
  SupabaseConceptLibraryBackend(this._db);

  final SupabaseClient _db;

  static const _criterionColumns =
      'id,sort_order,title,body,version,confirmed_at,draft_title,draft_body,draft_origin,draft_saved_at';
  static const _sourceColumns =
      'id,concept_id,academy_id,book_id,grade_label,raw_page,display_page,unit_path,created_at,resource_files(name)';

  Future<T> _guard<T>(Future<T> Function() run, {String? duplicate, String? denied}) async {
    try {
      return await run();
    } catch (e) {
      throw ConceptLibraryException.from(e, duplicate: duplicate, denied: denied);
    }
  }

  Map<String, dynamic> _expected(ConceptCriterion base) => {
        'p_id': base.id,
        'p_expected_version': base.version,
        'p_expected_draft_saved_at': base.draftSavedAtRaw,
      };

  static ConceptCriterion _row(Object? data) => ConceptCriterion.fromRow(Map<String, dynamic>.from(data as Map));

  @override
  Future<List<ConceptCriterion>> listCriteria() => _guard(() async {
        final rows = await _db
            .from('concept_criteria')
            .select(_criterionColumns)
            .order('sort_order', ascending: true)
            .order('created_at', ascending: true);
        return (rows as List).map((r) => ConceptCriterion.fromRow(Map<String, dynamic>.from(r as Map))).toList();
      });

  @override
  Future<ConceptCriterion> createCriterion({required String title, required String body, String origin = 'owner'}) =>
      _guard(() async => _row(
          await _db.rpc('concept_criteria_create', params: {'p_title': title, 'p_body': body, 'p_origin': origin})));

  @override
  Future<ConceptCriterion> saveDraft(ConceptCriterion base, {required String title, required String body}) =>
      _guard(() async => _row(await _db.rpc('concept_criteria_save_draft', params: {
            ..._expected(base),
            'p_title': title,
            'p_body': body,
          })));

  @override
  Future<ConceptCriterion> confirm(ConceptCriterion base, {String? note}) => _guard(() async => _row(
      await _db.rpc('concept_criteria_confirm', params: {..._expected(base), 'p_note': note})));

  @override
  Future<ConceptCriterion?> discardDraft(ConceptCriterion base) => _guard(() async {
        final data = Map<String, dynamic>.from(
            await _db.rpc('concept_criteria_discard_draft', params: _expected(base)) as Map);
        return data['removed'] == true ? null : ConceptCriterion.fromRow(data);
      });

  @override
  Future<List<ConceptCriterionRevision>> listRevisions(String criterionId) => _guard(() async {
        final rows = await _db
            .from('concept_criteria_revisions')
            .select('version,title,body,note,confirmed_at')
            .eq('criterion_id', criterionId)
            .order('version', ascending: false);
        return (rows as List).map((r) => ConceptCriterionRevision.fromRow(Map<String, dynamic>.from(r as Map))).toList();
      });

  @override
  Future<List<String>> criterionIdsForConcept(String conceptId) => _guard(() async {
        final rows = await _db.from('concept_criterion_links').select('criterion_id').eq('concept_id', conceptId);
        return (rows as List).map((r) => (r as Map)['criterion_id'] as String).toList();
      });

  @override
  Future<List<ConceptLinkedConcept>> conceptsForCriterion(String criterionId) => _guard(() async {
        final rows = await _db
            .from('concept_criterion_links')
            .select('concept_id,created_at,concepts(name,kind)')
            .eq('criterion_id', criterionId)
            .order('created_at', ascending: true);
        return (rows as List).map((r) {
          final m = Map<String, dynamic>.from(r as Map);
          final c = m['concepts'] is Map ? Map<String, dynamic>.from(m['concepts'] as Map) : const <String, dynamic>{};
          final kind = c['kind'] as String?;
          return ConceptLinkedConcept(
            conceptId: m['concept_id'] as String,
            name: c['name'] as String? ?? '',
            kind: kind == null ? null : ConceptKindX.fromDb(kind),
          );
        }).toList();
      });

  @override
  Future<void> link({required String criterionId, required String conceptId}) => _guard(
        () => _db.from('concept_criterion_links').insert({'criterion_id': criterionId, 'concept_id': conceptId}),
        duplicate: '이미 이어져 있습니다.',
        denied: '최고 관리자만 기준과 개념을 이을 수 있습니다.',
      );

  @override
  Future<void> unlink({required String criterionId, required String conceptId}) => _guard(() => _db
      .from('concept_criterion_links')
      .delete()
      .eq('criterion_id', criterionId)
      .eq('concept_id', conceptId));

  @override
  Future<List<ConceptSourceRef>> sourcesFor(String conceptId) => _guard(() async {
        final rows = await _db
            .from('concept_sources')
            .select(_sourceColumns)
            .eq('concept_id', conceptId)
            .order('created_at', ascending: true);
        return (rows as List).map((r) => ConceptSourceRef.fromRow(Map<String, dynamic>.from(r as Map))).toList();
      });

  @override
  Future<ConceptSourceRef> addSource({
    required String conceptId,
    required String academyId,
    required String bookId,
    required String gradeLabel,
    required int rawPage,
    int? displayPage,
    List<String> unitPath = const [],
  }) =>
      _guard(
        () async => ConceptSourceRef.fromRow(Map<String, dynamic>.from(await _db
            .from('concept_sources')
            .insert({
              'concept_id': conceptId,
              'academy_id': academyId,
              'book_id': bookId,
              'grade_label': gradeLabel,
              'raw_page': rawPage,
              'display_page': displayPage,
              'unit_path': unitPath.take(3).toList(),
            })
            .select(_sourceColumns)
            .single())),
        duplicate: '이 쪽은 이미 이 개념의 출처로 이어져 있습니다.',
        denied: '이 계정이 속한 학원의 교재만 출처로 이을 수 있습니다.',
      );

  @override
  Future<void> removeSource(String id) => _guard(() => _db.from('concept_sources').delete().eq('id', id));

  @override
  Future<String?> conceptTypeName(String conceptId) => _guard(() async {
        final row = await _db
            .from('concept_type_links')
            .select('type:concept_types(name)')
            .eq('concept_id', conceptId)
            .maybeSingle();
        final type = row?['type'];
        final name = type is Map ? '${type['name'] ?? ''}'.trim() : '';
        return name.isEmpty ? null : name;
      });
}
