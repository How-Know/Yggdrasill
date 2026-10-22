import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'concept_draft_service.dart';

/// 출처 근거 범위·근거 블록. 설계: docs/architecture/concept-library.md §4.3 (2단계)
/// 범위는 운영자가 정하거나 운영자가 AI 제안을 받아들일 때만 바뀐다. 기존 출처는 모두 "범위 미확인"이다.
enum ConceptEvidenceScope {
  whole('whole', '전체 근거', '이 서술 내용이 이 쪽 근거에 모두 있습니다.'),
  part('part', '일부 근거', '서술의 일부만 이 쪽 근거에 있습니다.'),
  related('related', '관련 설명', '같은 주제이지만 서술 내용을 직접 말하지 않습니다.'),
  unknown('unknown', '범위 미확인', '이 쪽이 서술을 얼마나 뒷받침하는지 아직 정하지 않았습니다.');

  const ConceptEvidenceScope(this.db, this.label, this.hint);

  final String db;
  final String label;
  final String hint;

  static ConceptEvidenceScope of(Object? v) =>
      ConceptEvidenceScope.values.where((s) => s.db == v).firstOrNull ?? ConceptEvidenceScope.unknown;
}

/// 초안 기록에 남은 근거 블록(교재 원문을 읽은 글).
class ConceptEvidenceBlock {
  const ConceptEvidenceBlock({
    required this.id,
    required this.rawPage,
    required this.kind,
    required this.title,
    required this.text,
    this.figureDescription = '',
    this.uncertain = false,
  });

  final String id;
  final int? rawPage;
  final String kind;
  final String title;
  final String text;
  final String figureDescription;
  final bool uncertain;

  factory ConceptEvidenceBlock.fromJson(Map<String, dynamic> j) => ConceptEvidenceBlock(
        id: '${j['id'] ?? ''}',
        rawPage: (j['raw_page'] as num?)?.toInt(),
        kind: '${j['kind'] ?? ''}',
        title: '${j['title'] ?? ''}',
        text: '${j['text'] ?? ''}',
        figureDescription: '${j['figure_description'] ?? ''}',
        uncertain: j['uncertain'] == true,
      );
}

class ConceptSourceEvidence {
  const ConceptSourceEvidence({
    required this.sourceId,
    required this.statementId,
    required this.scope,
    this.note,
    this.origin,
    this.setAtRaw,
    this.basisChanged = false,
    this.linked = false,
    this.draftFound = false,
    this.blocks = const [],
  });

  final String sourceId;

  /// null이면 기본 서술의 출처.
  final String? statementId;
  final ConceptEvidenceScope scope;
  final String? note;

  /// 'owner' | 'ai'(운영자가 AI 제안을 받아들임). 정한 적 없으면 null.
  final String? origin;

  /// 서버가 준 범위 시각 글자 그대로. 다시 정할 때 그대로 돌려준다.
  final String? setAtRaw;

  /// 범위를 정한 뒤 서술 글이 바뀌었다.
  final bool basisChanged;

  /// 초안 기록의 블록이 이어져 있다. [draftFound]가 false면 그 초안 기록이 지워졌다.
  final bool linked;
  final bool draftFound;
  final List<ConceptEvidenceBlock> blocks;

  DateTime? get setAt => setAtRaw == null ? null : DateTime.tryParse(setAtRaw!)?.toLocal();

  String get originLabel => switch (origin) {
        'ai' => 'AI 제안을 운영자가 받아들임',
        'owner' => '운영자가 정함',
        _ => '정한 적 없음',
      };

  factory ConceptSourceEvidence.fromJson(Map<String, dynamic> j) => ConceptSourceEvidence(
        sourceId: '${j['id']}',
        statementId: j['statement_id'] as String?,
        scope: ConceptEvidenceScope.of(j['evidence_scope']),
        note: j['evidence_note'] as String?,
        origin: j['evidence_origin'] as String?,
        setAtRaw: j['evidence_set_at']?.toString(),
        basisChanged: j['basis_changed'] == true,
        linked: j['draft_id'] != null,
        draftFound: j['draft_found'] == true,
        blocks: [
          for (final b in (j['blocks'] is List ? j['blocks'] as List : const []))
            if (b is Map) ConceptEvidenceBlock.fromJson(Map<String, dynamic>.from(b)),
        ],
      );
}

/// 출처가 뒷받침하는 서술 글. kind: base(기본 서술) | confirmed(다른 서술 확정본) | draft(확정 전).
class ConceptEvidenceBasis {
  const ConceptEvidenceBasis({required this.statementId, required this.kind, required this.md5});

  final String? statementId;
  final String kind;
  final String md5;
}

class ConceptEvidenceSnapshot {
  const ConceptEvidenceSnapshot({this.bases = const [], this.sources = const {}});

  final List<ConceptEvidenceBasis> bases;
  final Map<String, ConceptSourceEvidence> sources;

  factory ConceptEvidenceSnapshot.fromJson(Map<String, dynamic> j) => ConceptEvidenceSnapshot(
        bases: [
          for (final g in (j['groups'] is List ? j['groups'] as List : const []))
            if (g is Map)
              ConceptEvidenceBasis(
                statementId: g['statement_id'] as String?,
                kind: '${g['kind'] ?? ''}',
                md5: '${g['md5'] ?? ''}',
              ),
        ],
        sources: {
          for (final s in (j['sources'] is List ? j['sources'] as List : const []))
            if (s is Map) '${s['id']}': ConceptSourceEvidence.fromJson(Map<String, dynamic>.from(s)),
        },
      );
}

class ConceptEvidenceProposalItem {
  const ConceptEvidenceProposalItem({
    required this.sourceId,
    required this.scope,
    required this.currentScope,
    this.reason = '',
    this.covered = '',
    this.missing = '',
  });

  final String sourceId;
  final ConceptEvidenceScope scope;
  final ConceptEvidenceScope currentScope;
  final String reason;
  final String covered;
  final String missing;
}

/// AI 근거 범위 제안. 저장하지 않은 안이다. 받아들인 줄만 저장된다.
class ConceptEvidenceProposal {
  const ConceptEvidenceProposal({
    required this.statementId,
    required this.basisMd5,
    this.summary = '',
    this.items = const [],
    this.noBlocks = const [],
    this.unanswered = const [],
  });

  final String? statementId;
  final String basisMd5;
  final String summary;
  final List<ConceptEvidenceProposalItem> items;

  /// 근거 블록이 없어 AI에 보내지 않은 출처, AI가 답하지 않은 출처.
  final List<String> noBlocks;
  final List<String> unanswered;

  ConceptEvidenceProposal without(String sourceId) => ConceptEvidenceProposal(
        statementId: statementId,
        basisMd5: basisMd5,
        summary: summary,
        items: [
          for (final i in items)
            if (i.sourceId != sourceId) i
        ],
        noBlocks: noBlocks,
        unanswered: unanswered,
      );

  factory ConceptEvidenceProposal.fromJson(String? statementId, Map<String, dynamic> j) {
    final checks = j['checks'] is Map ? Map<String, dynamic>.from(j['checks'] as Map) : const <String, dynamic>{};
    List<String> ids(Object? v) => [for (final e in (v is List ? v : const [])) '$e'];
    return ConceptEvidenceProposal(
      statementId: statementId,
      basisMd5: '${j['basis_md5'] ?? ''}',
      summary: '${j['summary'] ?? ''}',
      items: [
        for (final i in (j['items'] is List ? j['items'] as List : const []))
          if (i is Map)
            ConceptEvidenceProposalItem(
              sourceId: '${i['source_id']}',
              scope: ConceptEvidenceScope.of(i['scope']),
              currentScope: ConceptEvidenceScope.of(i['current_scope']),
              reason: '${i['reason'] ?? ''}',
              covered: '${i['covered'] ?? ''}',
              missing: '${i['missing'] ?? ''}',
            ),
      ],
      noBlocks: ids(checks['no_blocks']),
      unanswered: ids(checks['unanswered']),
    );
  }
}

class ConceptEvidenceException implements Exception {
  ConceptEvidenceException(this.code, this.message);

  final String code;
  final String message;

  bool get notReady => code == 'not_ready';

  /// 다시 읽어야 하는 경우.
  bool get stale => code == 'concept_source_evidence_stale' || code == 'concept_source_basis_changed';

  static const Map<String, String> _messages = {
    'concept_source_evidence_stale': '그사이 이 출처의 근거 범위가 바뀌었습니다. 최신 값을 다시 읽었습니다.',
    'concept_source_basis_changed': '제안을 받은 뒤 서술이 바뀌어 받아들이지 않았습니다. 지금 서술로 다시 제안받으세요.',
    'concept_source_bad_scope': '알 수 없는 근거 범위입니다.',
    'concept_source_note_too_long': '범위 메모는 500자까지 쓸 수 있습니다.',
    'concept_source_concept_not_found': '이 개념을 찾을 수 없습니다(지워졌을 수 있습니다).',
    'concept_statement_source_not_found': '이 출처를 찾을 수 없습니다(빠졌을 수 있습니다).',
    'concept_statement_forbidden': '최고 관리자만 근거 범위를 볼 수 있습니다.',
    'no_evidence_blocks': '이 서술의 출처에 이어진 근거 블록이 없어 제안받을 수 없습니다. 범위는 직접 정해 주세요.',
    'evidence_not_ready': 'DB에 근거 범위 저장소가 아직 없습니다. 마이그레이션을 반영한 뒤 쓸 수 있습니다.',
    'too_many_sources': '출처가 너무 많은 서술입니다(30개까지).',
    'statement_not_found': '이 서술을 찾을 수 없습니다. 다시 열어 주세요.',
    'concept_not_found': '이 개념을 찾을 수 없습니다(지워졌을 수 있습니다).',
  };

  static String messageOf(String code, [String? fallback]) =>
      _messages[code] ?? conceptDraftErrorMessage(code, fallback);

  static ConceptEvidenceException from(Object e) {
    if (e is ConceptEvidenceException) return e;
    if (e is ConceptDraftException) return ConceptEvidenceException(e.code, messageOf(e.code, e.message));
    if (e is PostgrestException) {
      final code = e.code ?? '';
      final msg = e.message;
      for (final entry in _messages.entries) {
        if (msg.contains(entry.key)) return ConceptEvidenceException(entry.key, entry.value);
      }
      if (code == '42P01' || code == '42703' || code == 'PGRST205' || code == '42883' || code == 'PGRST202') {
        return ConceptEvidenceException('not_ready', _messages['evidence_not_ready']!);
      }
      return ConceptEvidenceException(code.isEmpty ? 'error' : code, msg);
    }
    return ConceptEvidenceException('error', e.toString());
  }

  @override
  String toString() => message;
}

abstract class ConceptEvidenceBackend {
  Future<ConceptEvidenceSnapshot> load(String conceptId);

  /// [origin] 'ai'는 운영자가 AI 제안을 받아들일 때이고 [basisMd5]가 필요하다.
  Future<void> setScope(
    ConceptSourceEvidence current, {
    required ConceptEvidenceScope scope,
    String? note,
    String origin = 'owner',
    String? basisMd5,
  });

  Future<ConceptEvidenceProposal> propose(String conceptId, String? statementId);
}

class SupabaseConceptEvidenceBackend implements ConceptEvidenceBackend {
  SupabaseConceptEvidenceBackend(this._db);

  final SupabaseClient _db;

  Future<T> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } catch (e) {
      throw ConceptEvidenceException.from(e);
    }
  }

  @override
  Future<ConceptEvidenceSnapshot> load(String conceptId) => _guard(() async {
        final data = await _db.rpc('concept_source_evidence', params: {'p_concept_id': conceptId});
        return ConceptEvidenceSnapshot.fromJson(Map<String, dynamic>.from(data as Map));
      });

  @override
  Future<void> setScope(
    ConceptSourceEvidence current, {
    required ConceptEvidenceScope scope,
    String? note,
    String origin = 'owner',
    String? basisMd5,
  }) =>
      _guard(() => _db.rpc('concept_source_set_evidence', params: {
            'p_source_id': current.sourceId,
            'p_scope': scope.db,
            'p_note': note,
            'p_expected_set_at': current.setAtRaw,
            'p_origin': origin,
            'p_basis_md5': basisMd5,
          }));

  @override
  Future<ConceptEvidenceProposal> propose(String conceptId, String? statementId) => _guard(() async {
        final res = await ConceptDraftService(client: _db).proposeEvidenceScopes(conceptId, statementId);
        final p = res['proposal'];
        if (p is! Map) throw ConceptEvidenceException('invalid_response', '서버 응답을 해석하지 못했습니다.');
        return ConceptEvidenceProposal.fromJson(statementId, Map<String, dynamic>.from(p));
      });
}

/// 출처 창 하나가 쓰는 근거 상태. 창을 닫으면 버린다(AI 제안도 저장하지 않았으므로 함께 사라진다).
class ConceptEvidenceController extends ChangeNotifier {
  ConceptEvidenceController(this._backend, this.conceptId);

  final ConceptEvidenceBackend _backend;
  final String conceptId;

  ConceptEvidenceSnapshot? snapshot;
  String? error;
  bool notReady = false;
  bool loading = false;
  final Set<String> busy = {};
  final Map<String?, ConceptEvidenceProposal> _proposals = {};
  final Set<String?> proposing = {};
  final Map<String?, String> proposeErrors = {};
  bool _disposed = false;
  int _loadSeq = 0;

  ConceptSourceEvidence? of(String sourceId) => snapshot?.sources[sourceId];
  ConceptEvidenceProposal? proposalFor(String? statementId) => _proposals[statementId];

  ConceptEvidenceProposalItem? proposalItem(String sourceId) {
    for (final p in _proposals.values) {
      for (final i in p.items) {
        if (i.sourceId == sourceId) return i;
      }
    }
    return null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() async {
    final seq = ++_loadSeq;
    loading = true;
    _notify();
    try {
      final s = await _backend.load(conceptId);
      if (_disposed || seq != _loadSeq) return;
      snapshot = s;
      error = null;
      notReady = false;
    } catch (e) {
      if (_disposed || seq != _loadSeq) return;
      final ex = ConceptEvidenceException.from(e);
      snapshot = null;
      error = ex.message;
      notReady = ex.notReady;
    }
    loading = false;
    _notify();
  }

  Future<String?> setScope(ConceptSourceEvidence current, ConceptEvidenceScope scope, String? note) =>
      _write(current, () => _backend.setScope(current, scope: scope, note: note));

  Future<String?> accept(ConceptEvidenceProposal proposal, ConceptEvidenceProposalItem item) async {
    final current = of(item.sourceId);
    if (current == null) return '이 출처를 찾을 수 없습니다(빠졌을 수 있습니다).';
    final err = await _write(
      current,
      () => _backend.setScope(current, scope: item.scope, note: null, origin: 'ai', basisMd5: proposal.basisMd5),
    );
    if (err == null) _drop(proposal.statementId, item.sourceId);
    return err;
  }

  /// 제안 한 줄을 버린다. 저장한 값은 그대로다.
  void reject(ConceptEvidenceProposal proposal, ConceptEvidenceProposalItem item) {
    _drop(proposal.statementId, item.sourceId);
    _notify();
  }

  void _drop(String? statementId, String sourceId) {
    final p = _proposals[statementId];
    if (p == null) return;
    final next = p.without(sourceId);
    if (next.items.isEmpty) {
      _proposals.remove(statementId);
    } else {
      _proposals[statementId] = next;
    }
  }

  Future<String?> _write(ConceptSourceEvidence current, Future<void> Function() run) async {
    if (busy.contains(current.sourceId)) return null;
    busy.add(current.sourceId);
    _notify();
    String? err;
    try {
      await run();
    } catch (e) {
      final ex = ConceptEvidenceException.from(e);
      err = ex.message;
      if (ex.code == 'concept_source_basis_changed') _proposals.remove(current.statementId);
    }
    busy.remove(current.sourceId);
    await load();
    return err;
  }

  Future<void> propose(String? statementId) async {
    if (proposing.contains(statementId)) return;
    proposing.add(statementId);
    proposeErrors.remove(statementId);
    _notify();
    try {
      final p = await _backend.propose(conceptId, statementId);
      if (_disposed) return;
      _proposals[statementId] = p;
    } catch (e) {
      if (_disposed) return;
      proposeErrors[statementId] = ConceptEvidenceException.from(e).message;
    }
    proposing.remove(statementId);
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// 마이그레이션 전이나 시험처럼 근거 저장소가 없을 때.
class ConceptEvidenceUnavailable implements ConceptEvidenceBackend {
  const ConceptEvidenceUnavailable();

  ConceptEvidenceException get _e =>
      ConceptEvidenceException('not_ready', ConceptEvidenceException.messageOf('evidence_not_ready'));

  @override
  Future<ConceptEvidenceSnapshot> load(String conceptId) async => throw _e;

  @override
  Future<void> setScope(ConceptSourceEvidence current,
          {required ConceptEvidenceScope scope, String? note, String origin = 'owner', String? basisMd5}) async =>
      throw _e;

  @override
  Future<ConceptEvidenceProposal> propose(String conceptId, String? statementId) async => throw _e;
}
