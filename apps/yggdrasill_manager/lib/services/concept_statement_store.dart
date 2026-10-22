import 'package:flutter/foundation.dart';

import 'concept_statement_service.dart';

/// 개념 상세에서 보는 서술·출처 서술·등장 위치. 개념별로 읽어 두고, 쓰기는 [ConceptStatementBackend]로만 한다.
/// 저장하지 않은 입력은 여기 두지 않는다(서술 고치기 창이 들고 있다).
class ConceptStatementStore extends ChangeNotifier {
  ConceptStatementStore(this._backendFactory);

  final ConceptStatementBackend Function() _backendFactory;
  ConceptStatementBackend? _backendCache;
  ConceptStatementBackend get _backend => _backendCache ??= _backendFactory();

  /// 계정이 바뀔 때마다 오른다. 앞 계정의 늦은 응답을 버린다.
  int _epoch = 0;

  final Map<String, List<ConceptStatement>> _statements = {};
  final Map<String, Map<String, String?>> _sourceStatement = {};
  final Map<String, List<ConceptAppearance>> _appearances = {};
  final Map<String, String> _errors = {};
  final Map<String, String?> _selected = {};
  final Map<String, ConceptContentDraft?> _contentDrafts = {};
  final Map<String, String> _contentDraftErrors = {};

  /// 마지막으로 실패한 쓰기의 오류 코드. 화면이 "본문이 바뀜" 같은 경우를 가려 다시 읽을 때 쓴다.
  String? lastErrorCode;

  /// DB에 서술 표가 아직 없다(마이그레이션 반영 전).
  bool notReady = false;

  /// 서버에 보내는 중(한 번에 하나).
  bool busy = false;

  /// 개념별 서술 수가 바뀌면 오른다. 트리는 이것만 듣는다.
  final ValueNotifier<int> countsTick = ValueNotifier<int>(0);

  void reset() {
    _epoch += 1;
    _statements.clear();
    _sourceStatement.clear();
    _appearances.clear();
    _errors.clear();
    _selected.clear();
    _contentDrafts.clear();
    _contentDraftErrors.clear();
    lastErrorCode = null;
    notReady = false;
    busy = false;
    countsTick.value += 1;
    notifyListeners();
  }

  bool loaded(String conceptId) => _statements.containsKey(conceptId);
  String? errorOf(String conceptId) => _errors[conceptId];

  ConceptStatement? coreOf(String conceptId) =>
      _statements[conceptId]?.where((s) => s.role == ConceptStatementRole.core).firstOrNull;

  /// 기본 서술(개념 본문)을 뺀 서술.
  List<ConceptStatement> statementsOf(String conceptId) => [
        for (final s in _statements[conceptId] ?? const <ConceptStatement>[])
          if (s.role == ConceptStatementRole.statement) s
      ];

  ConceptStatement? byId(String conceptId, String? id) {
    if (id == null) return null;
    return _statements[conceptId]?.where((s) => s.id == id).firstOrNull;
  }

  /// 읽은 적 없으면 null.
  int? statementCountOf(String conceptId) => loaded(conceptId) ? statementsOf(conceptId).length : null;

  /// 고른 서술. null이면 기본 서술.
  String? selectedOf(String conceptId) {
    final id = _selected[conceptId];
    return byId(conceptId, id) == null ? null : id;
  }

  void select(String conceptId, String? statementId) {
    if (selectedOf(conceptId) == statementId) return;
    _selected[conceptId] = statementId;
    notifyListeners();
  }

  /// 출처 id → 서술 id. 목록에 없는 출처(방금 이은 것 등)는 기본 서술이다.
  String? statementOfSource(String conceptId, String sourceId) => _sourceStatement[conceptId]?[sourceId];

  List<ConceptAppearance> appearancesOf(String conceptId, String? statementId) => [
        for (final a in _appearances[conceptId] ?? const <ConceptAppearance>[])
          if (a.statementId == statementId) a
      ];

  /// 기본 서술 수정안을 읽었는지. 읽지 못했으면 [contentDraftErrorOf]에 이유가 있다.
  bool contentDraftLoaded(String conceptId) => _contentDrafts.containsKey(conceptId);
  ConceptContentDraft? contentDraftOf(String conceptId) => _contentDrafts[conceptId];
  String? contentDraftErrorOf(String conceptId) => _contentDraftErrors[conceptId];

  Future<void> load(String conceptId) async {
    final epoch = _epoch;
    final draft = _readContentDraft(conceptId);
    try {
      final results = await Future.wait([
        _backend.statementsFor(conceptId),
        _backend.sourceStatements(conceptId),
        _backend.appearancesFor(conceptId),
      ]);
      if (epoch != _epoch) return;
      _statements[conceptId] = results[0] as List<ConceptStatement>;
      _sourceStatement[conceptId] = results[1] as Map<String, String?>;
      _appearances[conceptId] = results[2] as List<ConceptAppearance>;
      _errors.remove(conceptId);
      notReady = false;
      countsTick.value += 1;
    } catch (e) {
      if (epoch != _epoch) return;
      final ex = ConceptStatementException.from(e);
      notReady = ex.notReady;
      _errors[conceptId] = ex.message;
    }
    await draft;
    if (epoch != _epoch) return;
    notifyListeners();
  }

  /// 개념 상세 머리의 "수정안 있음"은 [countsTick]을 듣는다.
  void _setContentDraft(String conceptId, ConceptContentDraft? d, {bool known = true}) {
    final had = _contentDrafts[conceptId] != null;
    if (known) {
      _contentDrafts[conceptId] = d;
    } else {
      _contentDrafts.remove(conceptId);
    }
    if (had != (d != null)) countsTick.value += 1;
  }

  /// 서술과 따로 읽는다. 수정안 저장소가 아직 없어도 서술은 보인다. 읽지 못하면 옛 값을 지운다.
  Future<void> _readContentDraft(String conceptId) async {
    final epoch = _epoch;
    try {
      final d = await _backend.contentDraft(conceptId);
      if (epoch != _epoch) return;
      _setContentDraft(conceptId, d);
      _contentDraftErrors.remove(conceptId);
    } catch (e) {
      if (epoch != _epoch) return;
      final ex = ConceptStatementException.from(e);
      _setContentDraft(conceptId, null, known: false);
      _contentDraftErrors[conceptId] =
          ex.notReady ? 'DB에 기본 서술 수정안 저장소가 아직 없습니다. 마이그레이션을 반영한 뒤 쓸 수 있습니다.' : '기본 서술 수정안을 읽지 못했습니다: ${ex.message}';
    }
  }

  void conceptRemoved(String conceptId) {
    _statements.remove(conceptId);
    _sourceStatement.remove(conceptId);
    _appearances.remove(conceptId);
    _errors.remove(conceptId);
    _selected.remove(conceptId);
    _contentDrafts.remove(conceptId);
    _contentDraftErrors.remove(conceptId);
    countsTick.value += 1;
  }

  void _put(ConceptStatement row) {
    final list = _statements[row.conceptId] ?? [];
    final i = list.indexWhere((s) => s.id == row.id);
    if (i < 0) {
      list.add(row);
      countsTick.value += 1;
    } else {
      list[i] = row;
    }
    _statements[row.conceptId] = list;
  }

  /// 보내는 동안 [busy]. 받은 값은 같은 계정일 때만 [apply]로 반영한다.
  /// 실패하면 이유를 돌려주고, 그사이 바뀌었거나 없어졌으면 그 개념을 다시 읽는다.
  Future<(T?, String?)> _run<T>(String conceptId, Future<T> Function() send, void Function(T value) apply) async {
    if (busy) return (null, '앞 작업이 끝난 뒤 다시 해 주세요.');
    final epoch = _epoch;
    busy = true;
    lastErrorCode = null;
    notifyListeners();
    try {
      final out = await send();
      if (epoch != _epoch) return (null, null);
      apply(out);
      return (out, null);
    } catch (e) {
      if (epoch != _epoch) return (null, null);
      final ex = ConceptStatementException.from(e);
      lastErrorCode = ex.code;
      if (ex.stale || ex.code == 'concept_statement_not_found') await load(conceptId);
      if (ex.contentStale) await _readContentDraft(conceptId);
      return (null, ex.message);
    } finally {
      if (epoch == _epoch) {
        busy = false;
        notifyListeners();
      }
    }
  }

  /// 초안으로 만든다(확정하지 않는다). 서술이면 만든 서술을 고른다.
  Future<(ConceptStatement?, String?)> create(String conceptId, ConceptStatementRole role, ConceptStatementText text) =>
      _run(conceptId, () => _backend.create(conceptId: conceptId, role: role, text: text), (row) {
        _put(row);
        if (role == ConceptStatementRole.statement) _selected[conceptId] = row.id;
      });

  Future<(ConceptStatement?, String?)> saveDraft(ConceptStatement base, ConceptStatementText text) =>
      _run(base.conceptId, () => _backend.saveDraft(base, text), _put);

  Future<(ConceptStatement?, String?)> confirm(ConceptStatement base, {String? note}) =>
      _run(base.conceptId, () => _backend.confirm(base, note: note), _put);

  /// 확정한 적 없는 서술은 줄째 지워진다(첫 값 null, 오류도 null).
  Future<(ConceptStatement?, String?)> discardDraft(ConceptStatement base) =>
      _run<ConceptStatement?>(base.conceptId, () => _backend.discardDraft(base), (row) {
        if (row != null) {
          _put(row);
          return;
        }
        _statements[base.conceptId]?.removeWhere((s) => s.id == base.id);
        countsTick.value += 1;
      });

  /// 기본 서술 수정안 저장. [base]는 화면에 보였던 본문. 본문과 같은 글이면 수정안이 지워진다(첫 값 null, 오류도 null).
  Future<(ConceptContentDraft?, String?)> saveContentDraft(
    String conceptId, {
    required String content,
    String? note,
    required String base,
  }) =>
      _run<ConceptContentDraft?>(
        conceptId,
        () => _backend.saveContentDraft(
          conceptId: conceptId,
          content: content,
          note: note,
          base: base,
          current: _contentDrafts[conceptId],
        ),
        (d) {
          _setContentDraft(conceptId, d);
          _contentDraftErrors.remove(conceptId);
        },
      );

  /// 수정안을 본문으로 올린다. 확정한 뒤의 본문을 돌려준다.
  Future<(String?, String?)> confirmContentDraft(ConceptContentDraft draft, {required String note}) => _run(
      draft.conceptId,
      () => _backend.confirmContentDraft(draft, note: note),
      (_) => _setContentDraft(draft.conceptId, null));

  Future<String?> discardContentDraft(ConceptContentDraft draft) async {
    final (_, err) = await _run<void>(
      draft.conceptId,
      () => _backend.discardContentDraft(draft),
      (_) => _setContentDraft(draft.conceptId, null),
    );
    return err;
  }

  Future<List<ConceptStatementRevision>> revisions(String statementId) => _backend.revisions(statementId);
  Future<List<ConceptContentRevision>> contentRevisions(String conceptId) => _backend.contentRevisions(conceptId);

  Future<String?> setSourceStatement(String conceptId, String sourceId, String? statementId) async {
    final (_, err) = await _run<void>(
      conceptId,
      () => _backend.setSourceStatement(sourceId: sourceId, statementId: statementId),
      (_) => (_sourceStatement[conceptId] ??= {})[sourceId] = statementId,
    );
    return err;
  }

  Future<String?> addAppearance({
    required String conceptId,
    String? statementId,
    String? curriculumCode,
    required String schoolLevel,
    required String courseLabel,
    List<String> unitPath = const [],
    String? note,
  }) async {
    final (_, err) = await _run(
      conceptId,
      () => _backend.addAppearance(
        conceptId: conceptId,
        statementId: statementId,
        curriculumCode: curriculumCode,
        schoolLevel: schoolLevel,
        courseLabel: courseLabel,
        unitPath: unitPath,
        note: note,
      ),
      (row) => (_appearances[conceptId] ??= []).add(row),
    );
    return err;
  }

  Future<String?> removeAppearance(ConceptAppearance a) async {
    final (_, err) = await _run<void>(
      a.conceptId,
      () => _backend.removeAppearance(a.id),
      (_) => _appearances[a.conceptId]?.removeWhere((x) => x.id == a.id),
    );
    return err;
  }

  @override
  void dispose() {
    countsTick.dispose();
    super.dispose();
  }
}
