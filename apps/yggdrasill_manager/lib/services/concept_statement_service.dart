import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// 개념의 여러 서술·교육과정 등장 위치·개념 본문 고친 기록.
/// 설계: docs/architecture/concept-library.md §4.2
///
/// 개념 본문(concepts.content)은 그 개념의 "기본 서술"이고 이 표로 옮기지 않는다. 출처의 서술이 비어 있으면 기본 서술의 출처다.
/// 서술은 정리 기준처럼 확정본(content·version)과 저장된 초안(draft)을 따로 든다. 쓰기는 RPC로만 하고,
/// 화면에 보였던 판과 초안 저장 시각을 함께 보내 그사이 바뀌었으면 막는다(concept_statement_stale).
enum ConceptStatementRole { core, statement }

extension ConceptStatementRoleX on ConceptStatementRole {
  String get db => this == ConceptStatementRole.core ? 'core' : 'statement';
  String get label => this == ConceptStatementRole.core ? '개념 공통 내용' : '서술';

  static ConceptStatementRole fromDb(String? v) =>
      v == 'core' ? ConceptStatementRole.core : ConceptStatementRole.statement;
}

/// 서술 글이 원문 그대로인지, 우리가 정리한 글인지.
enum ConceptStatementBasis { organized, verbatim }

extension ConceptStatementBasisX on ConceptStatementBasis {
  String get db => name;
  String get label => this == ConceptStatementBasis.verbatim ? '원문 그대로' : '우리가 정리한 글';

  static ConceptStatementBasis fromDb(String? v) =>
      v == 'verbatim' ? ConceptStatementBasis.verbatim : ConceptStatementBasis.organized;
}

/// 원문에 이 서술의 조건이 적혀 있는지.
enum ConceptConditionsInSource { stated, omitted, checkContext }

extension ConceptConditionsInSourceX on ConceptConditionsInSource {
  String get db => switch (this) {
        ConceptConditionsInSource.stated => 'stated',
        ConceptConditionsInSource.omitted => 'omitted',
        ConceptConditionsInSource.checkContext => 'check_context',
      };
  String get label => switch (this) {
        ConceptConditionsInSource.stated => '원문에 조건이 적혀 있음',
        ConceptConditionsInSource.omitted => '원문에 조건이 없음(보완함)',
        ConceptConditionsInSource.checkContext => '원문에 안 보임 · 앞뒤 문맥 확인 필요',
      };

  static ConceptConditionsInSource? fromDb(String? v) => switch (v) {
        'stated' => ConceptConditionsInSource.stated,
        'omitted' => ConceptConditionsInSource.omitted,
        'check_context' => ConceptConditionsInSource.checkContext,
        _ => null,
      };
}

/// 서술(또는 개념 공통 내용) 한 판의 글. 서버가 같은 규칙으로 검사·정리한다(concept_statement_clean).
class ConceptStatementText {
  const ConceptStatementText({
    this.title = '',
    this.body = '',
    this.approach,
    this.conditions,
    this.conditionsInSource,
    this.terms = const [],
    this.basis = ConceptStatementBasis.organized,
    this.quote,
    this.supplementNote,
    this.unverifiedNote,
    this.meaning = '',
    this.scope,
  });

  /// 서술: 제목·본문(필수), 서술 방식("경우의 수", "집합과 기호" 등).
  final String title;
  final String body;
  final String? approach;

  /// 서술이면 이 서술의 적용 대상·조건, 공통 내용이면 공통 조건.
  final String? conditions;
  final ConceptConditionsInSource? conditionsInSource;
  final List<String> terms;
  final ConceptStatementBasis basis;

  /// 원문 또는 원문 참조. 우리가 보완한 문장을 여기 쓰지 않는다.
  final String? quote;
  final String? supplementNote;
  final String? unverifiedNote;

  /// 공통 내용: 공통 의미(필수)·적용 범위.
  final String meaning;
  final String? scope;

  static String? _s(Object? v) {
    final s = v?.toString();
    return s == null || s.trim().isEmpty ? null : s;
  }

  factory ConceptStatementText.fromJson(Map<String, dynamic> j) => ConceptStatementText(
        title: _s(j['title']) ?? '',
        body: _s(j['body']) ?? '',
        approach: _s(j['approach']),
        conditions: _s(j['conditions']),
        conditionsInSource: ConceptConditionsInSourceX.fromDb(j['conditions_in_source'] as String?),
        terms: j['terms'] is List ? [for (final t in j['terms'] as List) t.toString()] : const [],
        basis: ConceptStatementBasisX.fromDb(j['basis'] as String?),
        quote: _s(j['quote']),
        supplementNote: _s(j['supplement_note']),
        unverifiedNote: _s(j['unverified_note']),
        meaning: _s(j['meaning']) ?? '',
        scope: _s(j['scope']),
      );

  /// 그 역할의 칸만 보낸다. 빈 칸은 빼서 서버가 "없음"으로 저장한다.
  Map<String, dynamic> toJson(ConceptStatementRole role) {
    final out = <String, dynamic>{};
    void put(String k, String? v) {
      if (v != null && v.trim().isNotEmpty) out[k] = v;
    }

    if (role == ConceptStatementRole.core) {
      put('meaning', meaning);
      put('scope', scope);
      put('conditions', conditions);
      return out;
    }
    put('title', title.trim());
    put('body', body);
    put('approach', approach?.trim());
    put('conditions', conditions);
    if (conditionsInSource != null) out['conditions_in_source'] = conditionsInSource!.db;
    final cleanTerms = <String>[];
    for (final t in terms) {
      final v = t.trim();
      if (v.isNotEmpty && !cleanTerms.contains(v)) cleanTerms.add(v);
    }
    if (cleanTerms.isNotEmpty) out['terms'] = cleanTerms;
    out['basis'] = basis.db;
    put('quote', quote);
    put('supplement_note', supplementNote);
    put('unverified_note', unverifiedNote);
    return out;
  }
}

class ConceptStatement {
  const ConceptStatement({
    required this.id,
    required this.conceptId,
    required this.role,
    this.sortOrder = 0,
    this.version = 0,
    this.content,
    this.confirmedAt,
    this.draft,
    this.draftOrigin,
    this.draftSavedAtRaw,
  });

  final String id;
  final String conceptId;
  final ConceptStatementRole role;
  final int sortOrder;
  final int version;

  /// 확정본. 확정한 적 없으면 null.
  final ConceptStatementText? content;
  final DateTime? confirmedAt;

  /// 저장된 초안. 없으면 null.
  final ConceptStatementText? draft;

  /// 'owner'(운영자가 저장) · 'ai'(운영자가 승인한 AI 제안).
  final String? draftOrigin;

  /// 서버가 준 문자열 그대로(마이크로초까지). RPC 기대값으로 되돌려 보낸다.
  final String? draftSavedAtRaw;

  bool get confirmed => version > 0;
  bool get hasDraft => draft != null;

  /// 편집을 시작할 저장값: 초안이 있으면 초안, 없으면 확정본.
  ConceptStatementText get saved => draft ?? content ?? const ConceptStatementText();

  String get statusLabel {
    if (!confirmed) return '확정 전 초안';
    return hasDraft ? '확정 v$version · 저장된 초안 있음' : '확정 v$version';
  }

  static ConceptStatementText? _text(Object? v) =>
      v is Map ? ConceptStatementText.fromJson(Map<String, dynamic>.from(v)) : null;

  factory ConceptStatement.fromRow(Map<String, dynamic> r) => ConceptStatement(
        id: r['id'] as String,
        conceptId: r['concept_id'] as String,
        role: ConceptStatementRoleX.fromDb(r['role'] as String?),
        sortOrder: (r['sort_order'] as num?)?.toInt() ?? 0,
        version: (r['version'] as num?)?.toInt() ?? 0,
        content: _text(r['content']),
        confirmedAt: DateTime.tryParse(r['confirmed_at']?.toString() ?? '')?.toLocal(),
        draft: _text(r['draft']),
        draftOrigin: r['draft_origin'] as String?,
        draftSavedAtRaw: r['draft_saved_at']?.toString(),
      );
}

/// 서술 확정 기록 한 판.
class ConceptStatementRevision {
  const ConceptStatementRevision({required this.version, required this.content, this.note, this.confirmedAt});

  final int version;
  final ConceptStatementText content;
  final String? note;
  final DateTime? confirmedAt;

  factory ConceptStatementRevision.fromRow(Map<String, dynamic> r) => ConceptStatementRevision(
        version: (r['version'] as num?)?.toInt() ?? 0,
        content: r['content'] is Map
            ? ConceptStatementText.fromJson(Map<String, dynamic>.from(r['content'] as Map))
            : const ConceptStatementText(),
        note: r['note'] as String?,
        confirmedAt: DateTime.tryParse(r['confirmed_at']?.toString() ?? '')?.toLocal(),
      );
}

/// 문제은행과 같은 교육과정 코드·이름.
const Map<String, String> kConceptCurriculumLabels = {
  'legacy_1to6': '옛날 교육과정(1~6차)',
  'k7_1997': '7차 교육과정(1997)',
  'k7_2007': '2007 개정(7차)',
  'rev_2009': '2009 개정',
  'rev_2015': '2015 개정',
  'rev_2022': '2022 개정',
};

/// 교육과정 등장 위치. 운영자가 넣은 것만 있다. 교육과정 판을 모르면 비어 있다.
class ConceptAppearance {
  const ConceptAppearance({
    required this.id,
    required this.conceptId,
    required this.schoolLevel,
    required this.courseLabel,
    this.statementId,
    this.curriculumCode,
    this.unitPath = const [],
    this.note,
    this.createdAt,
  });

  final String id;
  final String conceptId;

  /// 비어 있으면 기본 서술(개념 본문).
  final String? statementId;
  final String? curriculumCode;
  final String schoolLevel;
  final String courseLabel;
  final List<String> unitPath;
  final String? note;
  final DateTime? createdAt;

  String get curriculumLabel =>
      curriculumCode == null ? '교육과정 판 미기록' : (kConceptCurriculumLabels[curriculumCode] ?? curriculumCode!);

  String get label {
    final unit = unitPath.isEmpty ? '' : ' · ${unitPath.join(' > ')}';
    return '$curriculumLabel · $schoolLevel $courseLabel$unit';
  }

  factory ConceptAppearance.fromRow(Map<String, dynamic> r) => ConceptAppearance(
        id: r['id'] as String,
        conceptId: r['concept_id'] as String,
        statementId: r['statement_id'] as String?,
        curriculumCode: r['curriculum_code'] as String?,
        schoolLevel: r['school_level'] as String? ?? '',
        courseLabel: r['course_label'] as String? ?? '',
        unitPath: (r['unit_path'] is List ? r['unit_path'] as List : const []).map((e) => e.toString()).toList(),
        note: r['note'] as String?,
        createdAt: DateTime.tryParse(r['created_at']?.toString() ?? '')?.toLocal(),
      );
}

/// 기존 개념 본문을 고치기 전 값.
class ConceptContentRevision {
  const ConceptContentRevision({
    required this.name,
    required this.content,
    this.changedAt,
    this.viaDraft = false,
    this.note,
    this.draftOrigin,
  });

  final String name;
  final String content;
  final DateTime? changedAt;

  /// 수정안을 확정해 바뀐 것. false면 수정안 없이 바로 고친 것(이유 없음).
  final bool viaDraft;
  final String? note;
  final String? draftOrigin;

  factory ConceptContentRevision.fromRow(Map<String, dynamic> r) => ConceptContentRevision(
        name: r['name'] as String? ?? '',
        content: r['content'] as String? ?? '',
        changedAt: DateTime.tryParse(r['changed_at']?.toString() ?? '')?.toLocal(),
        viaDraft: r['via'] == 'draft',
        note: r['note'] as String?,
        draftOrigin: r['draft_origin'] as String?,
      );
}

/// 서버 md5(text)와 같은 값(UTF-8).
String conceptContentMd5(String text) => md5.convert(utf8.encode(text)).toString();

/// 기본 서술(개념 본문) 수정안. 개념마다 하나이고, 확정해야 본문이 된다.
class ConceptContentDraft {
  const ConceptContentDraft({
    required this.conceptId,
    required this.content,
    required this.baseMd5,
    this.note,
    this.origin = 'owner',
    this.savedAtRaw,
  });

  final String conceptId;
  final String content;

  /// 수정안을 쓸 때 본 본문의 md5.
  final String baseMd5;

  /// 왜 고치려는지.
  final String? note;

  /// 'owner'(운영자가 씀) · 'ai'(운영자가 승인한 AI 제안).
  final String origin;

  /// 서버가 준 문자열 그대로(마이크로초까지). RPC 기대값으로 되돌려 보낸다.
  final String? savedAtRaw;

  DateTime? get savedAt => DateTime.tryParse(savedAtRaw ?? '')?.toLocal();
  String get originLabel => origin == 'ai' ? 'AI 제안(운영자 승인)' : '운영자 작성';

  /// 이 본문을 보고 쓴 수정안인지. 아니면 그 뒤 본문이 바뀐 것이다.
  bool basedOn(String content) => conceptContentMd5(content) == baseMd5;

  factory ConceptContentDraft.fromRow(Map<String, dynamic> r) => ConceptContentDraft(
        conceptId: r['concept_id'] as String,
        content: r['content'] as String? ?? '',
        baseMd5: r['base_md5'] as String? ?? '',
        note: r['note'] as String?,
        origin: r['origin'] as String? ?? 'owner',
        savedAtRaw: r['saved_at']?.toString(),
      );
}

class ConceptStatementException implements Exception {
  ConceptStatementException(this.code, this.message);

  final String code;
  final String message;

  /// DB 마이그레이션 전이라 표·열·함수가 없다.
  bool get notReady => code == 'not_ready';
  bool get stale => code == 'concept_statement_stale';

  static const Map<String, String> _messages = {
    'concept_statement_stale': '그사이 이 서술이 바뀌었습니다. 최신 저장본을 다시 불러온 뒤 이어서 고쳐 주세요(지금 입력한 내용은 남아 있습니다).',
    'concept_statement_not_found': '이 서술을 찾을 수 없습니다(지워졌을 수 있습니다).',
    'concept_statement_concept_not_found': '이 개념을 찾을 수 없습니다(지워졌을 수 있습니다).',
    'concept_statement_forbidden': '최고 관리자만 서술을 바꿀 수 있습니다.',
    'concept_statement_bad_role': '알 수 없는 서술 종류입니다.',
    'concept_statement_core_exists': '이 개념에는 이미 공통 내용이 있습니다. 있는 공통 내용을 고쳐 주세요.',
    'concept_statement_unknown_field': '서버가 모르는 칸이 들어 있습니다. 앱을 새로 받은 뒤 다시 해 주세요.',
    'concept_statement_bad_content': '서술 내용의 형식이 맞지 않습니다.',
    'concept_statement_title_required': '서술 제목을 입력하세요.',
    'concept_statement_body_required': '서술 본문을 입력하세요.',
    'concept_statement_meaning_required': '공통 의미를 입력하세요.',
    'concept_statement_too_long': '글이 너무 깁니다(제목 200자, 본문 20,000자, 조건·원문 4,000자, 용어 30개·각 60자).',
    'concept_statement_no_draft': '저장된 초안이 없습니다.',
    'concept_statement_in_use': '이 서술에 출처나 등장 위치가 붙어 있어 지우지 않았습니다. 먼저 출처·등장 위치를 빼거나 다른 서술로 옮겨 주세요.',
    'concept_statement_other_concept': '다른 개념의 서술에는 이을 수 없습니다.',
    'concept_statement_not_statement': '개념 공통 내용에는 출처·등장 위치를 잇지 않습니다. 서술을 골라 주세요.',
    'concept_statement_source_not_found': '이 출처를 찾을 수 없습니다(빠졌을 수 있습니다).',
    'concept_content_stale': '그사이 기본 서술(개념 본문)이 바뀌었습니다. 최신 본문을 다시 읽었으니 비교한 뒤 다시 저장해 주세요(입력한 수정안은 남아 있습니다).',
    'concept_content_draft_stale': '그사이 이 수정안이 바뀌었습니다. 최신 수정안을 다시 읽었습니다(입력한 내용은 남아 있습니다).',
    'concept_content_base_changed': '수정안을 쓴 뒤 기본 서술이 바뀌어 확정하지 않았습니다. 지금 본문과 비교해 수정안을 다시 저장한 뒤 확정하세요.',
    'concept_content_concept_not_found': '이 개념을 찾을 수 없습니다(지워졌을 수 있습니다).',
    'concept_content_required': '수정안 본문을 입력하세요.',
    'concept_content_too_long': '글이 너무 깁니다(본문 40,000자, 이유 2,000자).',
    'concept_content_no_draft': '저장된 수정안이 없습니다.',
    'concept_content_note_required': '왜 고치는지 이유를 적어야 확정합니다.',
  };

  /// 그사이 본문·수정안이 바뀌어 다시 읽어야 하는 경우.
  bool get contentStale =>
      code == 'concept_content_stale' ||
      code == 'concept_content_draft_stale' ||
      code == 'concept_content_base_changed';

  static ConceptStatementException from(Object e, {String? duplicate, String? denied}) {
    if (e is ConceptStatementException) return e;
    if (e is PostgrestException) {
      final code = e.code ?? '';
      final msg = e.message;
      for (final entry in _messages.entries) {
        if (msg.contains(entry.key)) return ConceptStatementException(entry.key, entry.value);
      }
      if (code == '42P01' ||
          code == '42703' ||
          code == 'PGRST205' ||
          code == 'PGRST204' ||
          code == '42883' ||
          code == 'PGRST202') {
        return ConceptStatementException('not_ready', 'DB에 서술·등장 위치 저장소가 아직 없습니다. 마이그레이션을 반영한 뒤 쓸 수 있습니다.');
      }
      if (code == '23505') return ConceptStatementException('duplicate', duplicate ?? '이미 저장되어 있습니다.');
      if (code == '42501') return ConceptStatementException('denied', denied ?? '이 계정으로는 할 수 없는 작업입니다.');
      return ConceptStatementException(code.isEmpty ? 'error' : code, msg);
    }
    return ConceptStatementException('error', e.toString());
  }

  @override
  String toString() => message;
}

/// 화면·시험이 같은 규칙으로 쓰도록 저장소를 감춘다. 시험은 메모리 구현을 쓴다.
abstract class ConceptStatementBackend {
  /// 공통 내용(있으면 하나)과 서술. 역할, 순서, 만든 때 순.
  Future<List<ConceptStatement>> statementsFor(String conceptId);
  Future<ConceptStatement> create({
    required String conceptId,
    required ConceptStatementRole role,
    required ConceptStatementText text,
  });
  Future<ConceptStatement> saveDraft(ConceptStatement base, ConceptStatementText text);
  Future<ConceptStatement> confirm(ConceptStatement base, {String? note});

  /// 확정한 적 없는 서술은 줄째 지워지고 null을 돌려준다.
  Future<ConceptStatement?> discardDraft(ConceptStatement base);
  Future<List<ConceptStatementRevision>> revisions(String statementId);

  /// 개념 출처 id → 서술 id(기본 서술이면 null).
  Future<Map<String, String?>> sourceStatements(String conceptId);
  Future<void> setSourceStatement({required String sourceId, String? statementId});

  Future<List<ConceptAppearance>> appearancesFor(String conceptId);
  Future<ConceptAppearance> addAppearance({
    required String conceptId,
    String? statementId,
    String? curriculumCode,
    required String schoolLevel,
    required String courseLabel,
    List<String> unitPath = const [],
    String? note,
  });
  Future<void> removeAppearance(String id);

  /// 기존 개념 본문을 고치기 전 값. 최근 것부터.
  Future<List<ConceptContentRevision>> contentRevisions(String conceptId);

  /// 기본 서술 수정안. 없으면 null.
  Future<ConceptContentDraft?> contentDraft(String conceptId);

  /// [base]는 화면에 보였던 본문, [current]는 화면에 보였던 수정안(없었으면 null).
  /// 본문과 같은 글이면 수정안이 지워지고 null을 돌려준다.
  Future<ConceptContentDraft?> saveContentDraft({
    required String conceptId,
    required String content,
    String? note,
    required String base,
    ConceptContentDraft? current,
  });

  /// 확정한 뒤의 본문을 돌려준다.
  Future<String> confirmContentDraft(ConceptContentDraft draft, {required String note});
  Future<void> discardContentDraft(ConceptContentDraft draft);
}

class SupabaseConceptStatementBackend implements ConceptStatementBackend {
  SupabaseConceptStatementBackend(this._db);

  final SupabaseClient _db;

  static const _columns =
      'id,concept_id,role,sort_order,version,content,confirmed_at,draft,draft_origin,draft_saved_at';
  static const _appearanceColumns =
      'id,concept_id,statement_id,curriculum_code,school_level,course_label,unit_path,note,created_at';

  Future<T> _guard<T>(Future<T> Function() run, {String? duplicate, String? denied}) async {
    try {
      return await run();
    } catch (e) {
      throw ConceptStatementException.from(e, duplicate: duplicate, denied: denied);
    }
  }

  Map<String, dynamic> _expected(ConceptStatement base) => {
        'p_id': base.id,
        'p_expected_version': base.version,
        'p_expected_draft_saved_at': base.draftSavedAtRaw,
      };

  static ConceptStatement _row(Object? data) => ConceptStatement.fromRow(Map<String, dynamic>.from(data as Map));

  @override
  Future<List<ConceptStatement>> statementsFor(String conceptId) => _guard(() async {
        final rows = await _db
            .from('concept_statements')
            .select(_columns)
            .eq('concept_id', conceptId)
            .order('role', ascending: true)
            .order('sort_order', ascending: true)
            .order('created_at', ascending: true);
        return (rows as List).map((r) => ConceptStatement.fromRow(Map<String, dynamic>.from(r as Map))).toList();
      });

  @override
  Future<ConceptStatement> create({
    required String conceptId,
    required ConceptStatementRole role,
    required ConceptStatementText text,
  }) =>
      _guard(() async => _row(await _db.rpc('concept_statement_create', params: {
            'p_concept_id': conceptId,
            'p_role': role.db,
            'p_content': text.toJson(role),
          })));

  @override
  Future<ConceptStatement> saveDraft(ConceptStatement base, ConceptStatementText text) =>
      _guard(() async => _row(await _db.rpc('concept_statement_save_draft', params: {
            ..._expected(base),
            'p_content': text.toJson(base.role),
          })));

  @override
  Future<ConceptStatement> confirm(ConceptStatement base, {String? note}) => _guard(
      () async => _row(await _db.rpc('concept_statement_confirm', params: {..._expected(base), 'p_note': note})));

  @override
  Future<ConceptStatement?> discardDraft(ConceptStatement base) => _guard(() async {
        final data =
            Map<String, dynamic>.from(await _db.rpc('concept_statement_discard_draft', params: _expected(base)) as Map);
        return data['removed'] == true ? null : ConceptStatement.fromRow(data);
      });

  @override
  Future<List<ConceptStatementRevision>> revisions(String statementId) => _guard(() async {
        final rows = await _db
            .from('concept_statement_revisions')
            .select('version,content,note,confirmed_at')
            .eq('statement_id', statementId)
            .order('version', ascending: false);
        return (rows as List)
            .map((r) => ConceptStatementRevision.fromRow(Map<String, dynamic>.from(r as Map)))
            .toList();
      });

  @override
  Future<Map<String, String?>> sourceStatements(String conceptId) => _guard(() async {
        final rows = await _db.from('concept_sources').select('id,statement_id').eq('concept_id', conceptId);
        return {for (final r in rows as List) (r as Map)['id'] as String: r['statement_id'] as String?};
      });

  @override
  Future<void> setSourceStatement({required String sourceId, String? statementId}) => _guard(
        () => _db.rpc('concept_source_set_statement', params: {'p_source_id': sourceId, 'p_statement_id': statementId}),
        duplicate: '이 쪽은 이미 그 서술의 출처로 이어져 있습니다. 같은 서술에 같은 쪽을 두 번 잇지 않습니다.',
      );

  @override
  Future<List<ConceptAppearance>> appearancesFor(String conceptId) => _guard(() async {
        final rows = await _db
            .from('concept_appearances')
            .select(_appearanceColumns)
            .eq('concept_id', conceptId)
            .order('created_at', ascending: true);
        return (rows as List).map((r) => ConceptAppearance.fromRow(Map<String, dynamic>.from(r as Map))).toList();
      });

  @override
  Future<ConceptAppearance> addAppearance({
    required String conceptId,
    String? statementId,
    String? curriculumCode,
    required String schoolLevel,
    required String courseLabel,
    List<String> unitPath = const [],
    String? note,
  }) =>
      _guard(
        () async => ConceptAppearance.fromRow(Map<String, dynamic>.from(await _db
            .from('concept_appearances')
            .insert({
              'concept_id': conceptId,
              'statement_id': statementId,
              'curriculum_code': curriculumCode,
              'school_level': schoolLevel,
              'course_label': courseLabel.trim(),
              'unit_path': [for (final u in unitPath.take(3)) u.trim()],
              'note': (note ?? '').trim().isEmpty ? null : note!.trim(),
            })
            .select(_appearanceColumns)
            .single())),
        duplicate: '같은 등장 위치가 이미 있습니다.',
        denied: '최고 관리자만 등장 위치를 넣을 수 있습니다.',
      );

  @override
  Future<void> removeAppearance(String id) => _guard(() => _db.from('concept_appearances').delete().eq('id', id));

  @override
  Future<List<ConceptContentRevision>> contentRevisions(String conceptId) async {
    Future<List<ConceptContentRevision>> read(String columns) => _guard(() async {
          final rows = await _db
              .from('concept_content_revisions')
              .select(columns)
              .eq('concept_id', conceptId)
              .order('changed_at', ascending: false);
          return (rows as List)
              .map((r) => ConceptContentRevision.fromRow(Map<String, dynamic>.from(r as Map)))
              .toList();
        });
    try {
      return await read('name,content,changed_at,via,note,draft_origin');
    } on ConceptStatementException catch (e) {
      // 수정안 마이그레이션 전에는 이유 열이 없다.
      if (!e.notReady) rethrow;
      return read('name,content,changed_at');
    }
  }

  @override
  Future<ConceptContentDraft?> contentDraft(String conceptId) => _guard(() async {
        final row = await _db
            .from('concept_content_drafts')
            .select('concept_id,content,base_md5,note,origin,saved_at')
            .eq('concept_id', conceptId)
            .maybeSingle();
        return row == null ? null : ConceptContentDraft.fromRow(Map<String, dynamic>.from(row));
      });

  @override
  Future<ConceptContentDraft?> saveContentDraft({
    required String conceptId,
    required String content,
    String? note,
    required String base,
    ConceptContentDraft? current,
  }) =>
      _guard(() async {
        final data = Map<String, dynamic>.from(await _db.rpc('concept_content_save_draft', params: {
          'p_concept_id': conceptId,
          'p_content': content,
          'p_note': note,
          'p_base_md5': conceptContentMd5(base),
          'p_expected_saved_at': current?.savedAtRaw,
        }) as Map);
        return data['removed'] == true ? null : ConceptContentDraft.fromRow(data);
      });

  @override
  Future<String> confirmContentDraft(ConceptContentDraft draft, {required String note}) => _guard(() async {
        final data = Map<String, dynamic>.from(await _db.rpc('concept_content_confirm', params: {
          'p_concept_id': draft.conceptId,
          'p_expected_saved_at': draft.savedAtRaw,
          'p_note': note,
        }) as Map);
        return data['content'] as String? ?? draft.content;
      });

  @override
  Future<void> discardContentDraft(ConceptContentDraft draft) => _guard(() => _db.rpc('concept_content_discard_draft',
      params: {'p_concept_id': draft.conceptId, 'p_expected_saved_at': draft.savedAtRaw}));
}
