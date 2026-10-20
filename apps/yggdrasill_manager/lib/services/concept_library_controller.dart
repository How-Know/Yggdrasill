import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_service.dart';
import 'concept_library_service.dart';
import 'concept_relation_service.dart';
import 'concept_relation_store.dart';
import 'concept_service.dart';
import 'concept_statement_service.dart';
import 'concept_statement_store.dart';
import 'think/think_concept_chat_controller.dart';

/// 시험에서 서술 저장소를 주지 않았을 때. 답하지 않아 서술 칸이 읽는 중으로 남는다.
class _NeverStatementBackend implements ConceptStatementBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

/// 시험에서 관계 저장소를 주지 않았을 때. 관계 칸이 읽는 중으로 남는다.
class _NeverRelationBackend implements ConceptRelationBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

/// 개념 탭에서 크게(상세) 보는 쪽. 다른 쪽은 요약으로 보인다. 좁은 화면에서는 보이는 칸이다.
enum ConceptWorkspaceFocus { criteria, library }

/// 처음 항목을 만들 때 한 번 넣는 기본 틀. 코드가 항목을 따로 다루지 않는다(만든 뒤에는 일반 항목과 같다).
class ConceptCriterionTemplate {
  const ConceptCriterionTemplate(this.title, this.body);

  final String title;
  final String body;
}

const List<ConceptCriterionTemplate> kConceptCriterionTemplates = [
  ConceptCriterionTemplate(
    '지식 분류 기준',
    '(기본 틀 — 아직 확정한 기준이 아닙니다. 고쳐서 저장하고, 확정해야 기준이 됩니다.)\n\n'
        '출발점: 개정 Bloom 분류의 지식 차원 4가지\n'
        '- 사실적 지식: 용어, 기호, 구체적인 사실\n'
        '- 개념적 지식: 분류와 범주, 원리와 일반화, 이론·모형·구조\n'
        '- 절차적 지식: 계산·풀이 절차와 기법, 어떤 절차를 언제 쓸지에 대한 판단\n'
        '- 메타인지 지식: 전략에 대한 지식, 과제에 대한 지식, 자기 자신에 대한 지식\n\n'
        '정할 것\n'
        '- 이 4가지를 그대로 쓸지, 수학 개념 정리에 맞게 바꿀지\n'
        '- 기존 라이브러리의 정의·정리 구분과 어떻게 관계 지을지(자동으로 대응시키지 않음)',
  ),
  ConceptCriterionTemplate(
    '노드 분리·통합 기준',
    '(기본 틀 — 아직 확정한 기준이 아닙니다.)\n\n'
        '정할 것\n'
        '- 개념 하나(노드)에 담을 범위\n'
        '- 언제 둘로 나누고, 언제 하나로 합칠지\n'
        '- 교재마다 묶음이 다를 때 어떻게 처리할지',
  ),
  ConceptCriterionTemplate(
    '대표 용어와 다른 표현 처리',
    '(기본 틀 — 아직 확정한 기준이 아닙니다.)\n\n'
        '정할 것\n'
        '- 대표 용어를 무엇으로 정할지(교육과정 용어, 교과서 용어 등)\n'
        '- 같은 뜻의 다른 표현·기호를 어디에 적을지\n'
        '- 학년에 따라 표현이 바뀌는 경우',
  ),
  ConceptCriterionTemplate(
    '개념 사이의 관계 정의',
    '(기본 틀 — 아직 확정한 기준이 아닙니다.)\n\n'
        '정할 것\n'
        '- 쓸 관계의 종류(예: 먼저 알아야 하는 개념, 확장, 특수한 경우, 같은 개념의 다른 표현)\n'
        '- 관계의 방향을 어떻게 읽을지\n'
        '- 관계를 누가 언제 확정할지',
  ),
  ConceptCriterionTemplate(
    '확정 사례와 예외',
    '(기본 틀 — 아직 확정한 기준이 아닙니다.)\n\n'
        '- 위 기준을 실제 개념에 적용해 확정한 사례\n'
        '- 기준에 맞지 않지만 예외로 둔 경우와 그 이유',
  ),
];

/// 기준 하나의 편집 칸. 시작한 저장값(base)과 다르면 "저장 안 됨"이다.
class CriterionEdit {
  CriterionEdit(String title, String body)
      : title = TextEditingController(text: title),
        body = TextEditingController(text: body),
        _baseTitle = title,
        _baseBody = body;

  final TextEditingController title;
  final TextEditingController body;
  String _baseTitle;
  String _baseBody;

  bool get dirty => title.text != _baseTitle || body.text != _baseBody;
  Listenable get listenable => Listenable.merge([title, body]);

  /// 새 저장값을 기준으로 삼는다. keepText면 입력한 글은 그대로 둔다(저장 중에 더 고쳤거나, 남이 먼저 바꾼 경우).
  void rebase(String t, String b, {bool keepText = false}) {
    _baseTitle = t;
    _baseBody = b;
    if (keepText) return;
    if (title.text != t) title.text = t;
    if (body.text != b) body.text = b;
  }

  void dispose() {
    title.dispose();
    body.dispose();
  }
}

/// 개념 탭 작업 공간의 상태. 메뉴를 옮겨 다녀도(화면이 다시 만들어져도) 고르던 항목과 저장 안 한 입력이 남는다.
/// 확대·축소(초점 바꾸기)는 상태만 바꾸고 저장·확정·AI 요청을 하지 않는다.
class ConceptLibraryController extends ChangeNotifier {
  ConceptLibraryController._(this._backendFactory, this._chatFactory, this.statements, this.relations);

  static final ConceptLibraryController instance = ConceptLibraryController._(
    () => SupabaseConceptLibraryBackend(Supabase.instance.client),
    () => ConceptChatController.instance,
    ConceptStatementStore(() => SupabaseConceptStatementBackend(Supabase.instance.client)),
    ConceptRelationStore(() => SupabaseConceptRelationBackend(Supabase.instance.client)),
  );

  /// 시험은 `ConceptChatController.forTest()`를 함께 넘긴다. 서술·관계 저장소를 안 주면 그 칸은 "읽는 중"에 머문다.
  @visibleForTesting
  factory ConceptLibraryController.forTest(
    ConceptLibraryBackend backend, {
    required ConceptChatController chat,
    ConceptStatementBackend? statementBackend,
    ConceptRelationBackend? relationBackend,
  }) =>
      ConceptLibraryController._(
        () => backend,
        () => chat,
        ConceptStatementStore(() => statementBackend ?? _NeverStatementBackend()),
        ConceptRelationStore(() => relationBackend ?? _NeverRelationBackend()),
      )
        .._started = true
        .._attachChat();

  final ConceptLibraryBackend Function() _backendFactory;
  final ConceptChatController Function() _chatFactory;

  /// 개념의 여러 서술·등장 위치(`concept-library.md` §4.2).
  final ConceptStatementStore statements;

  /// 개념 사이 관계·검토 필요 표시(`concept-library.md` §4.2).
  final ConceptRelationStore relations;
  ConceptLibraryBackend? _backendCache;
  ConceptLibraryBackend get _backend => _backendCache ??= _backendFactory();
  ConceptChatController get chat => _chatFactory();

  bool _started = false;
  String? _userId;

  /// 계정이 바뀔 때마다 오른다. 앞 계정의 늦은 응답이 새 계정 화면을 덮지 않게 한다.
  int _epoch = 0;

  void _attachChat() => chat.attachStatements(statements);

  void ensureStarted() {
    if (_started) return;
    _started = true;
    _attachChat();
    _userId = AuthService.currentUser?.id;
    unawaited(relations.loadOpen());
    AuthService.authStateChanges.listen((s) {
      final uid = s.session?.user.id;
      if (uid == _userId) return;
      _userId = uid;
      _resetForAccount();
      if (uid != null) unawaited(relations.loadOpen());
    });
  }

  @visibleForTesting
  void resetForAccountTest() => _resetForAccount();

  /// 입력 칸이 아직 화면에 붙어 있을 수 있어, 다음 프레임 뒤에 닫는다.
  void _disposeLater(Iterable<CriterionEdit> edits) {
    final list = edits.toList();
    if (list.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final e in list) {
        e.dispose();
      }
    });
  }

  void _resetForAccount() {
    _epoch += 1;
    _disposeLater(_edits.values);
    _edits.clear();
    criteria = const [];
    _localNew.clear();
    loading = false;
    loaded = false;
    loadError = null;
    notReady = false;
    selectedCriterionId = null;
    selectedConcept = null;
    openedConceptId.value = null;
    errors.clear();
    busyId = null;
    templateBusy = false;
    _criteriaOfConcept.clear();
    _criteriaOfConceptError.clear();
    _conceptsOfCriterion.clear();
    _conceptsOfCriterionError.clear();
    _sources.clear();
    _sourcesError.clear();
    _types.clear();
    _typesFailed.clear();
    statements.reset();
    relations.reset();
    notifyListeners();
  }

  // ------------------------------------------------------------------ 초점
  ConceptWorkspaceFocus focus = ConceptWorkspaceFocus.library;

  /// 좁은 화면에서 Think 대화를 세 번째 칸으로 보고 있는지.
  bool narrowChat = false;

  void setFocus(ConceptWorkspaceFocus f) {
    if (focus == f && !narrowChat) return;
    focus = f;
    narrowChat = false;
    notifyListeners();
  }

  void showNarrowChat() {
    if (narrowChat) return;
    narrowChat = true;
    notifyListeners();
  }

  // ------------------------------------------------------------------ 정리 기준
  List<ConceptCriterion> criteria = const [];
  final List<String> _localNew = [];
  int _localSeq = 0;
  bool loading = false;
  bool loaded = false;

  /// DB에 표·함수가 아직 없다(마이그레이션 반영 전).
  bool notReady = false;
  String? loadError;
  String? selectedCriterionId;

  /// 서버에 보내는 중인 기준(한 번에 하나).
  String? busyId;
  bool templateBusy = false;

  /// 기준별 마지막 오류. 입력은 그대로 둔다.
  final Map<String, String> errors = {};
  final Map<String, CriterionEdit> _edits = {};

  /// 서버 항목, 그다음 아직 저장하지 않은 새 항목.
  List<String> get itemIds => [for (final c in criteria) c.id, ..._localNew];
  bool isLocal(String id) => _localNew.contains(id);
  ConceptCriterion? criterionById(String? id) {
    if (id == null) return null;
    for (final c in criteria) {
      if (c.id == id) return c;
    }
    return null;
  }

  ConceptCriterion? get selectedCriterion => criterionById(selectedCriterionId);

  CriterionEdit editOf(String id) => _edits.putIfAbsent(id, () {
        final c = criterionById(id);
        return CriterionEdit(c?.savedTitle ?? '', c?.savedBody ?? '');
      });

  CriterionEdit? peekEdit(String id) => _edits[id];

  /// 저장하지 않은 입력이 있다(새 항목은 아직 서버에 없으니 항상 그렇다).
  bool isDirty(String id) => isLocal(id) || (_edits[id]?.dirty ?? false);
  bool get hasUnsaved => itemIds.any(isDirty);

  Future<void> loadCriteria() async {
    final epoch = _epoch;
    loading = true;
    loadError = null;
    notifyListeners();
    try {
      final rows = await _backend.listCriteria();
      if (epoch != _epoch) return;
      criteria = rows;
      loaded = true;
      notReady = false;
      final ids = rows.map((c) => c.id).toSet();
      for (final c in rows) {
        final e = _edits[c.id];
        if (e != null) e.rebase(c.savedTitle, c.savedBody, keepText: e.dirty);
      }
      // 다른 곳에서 지워진 항목: 고치던 글이 있으면 새 항목으로 남겨 잃지 않는다.
      for (final id in _edits.keys.toList()) {
        if (ids.contains(id) || _localNew.contains(id)) continue;
        final e = _edits[id]!;
        if (e.dirty) {
          _localNew.add(id);
          errors[id] = '이 기준은 다른 곳에서 지워졌습니다. 고치던 글은 남겨 두었으니, 저장하면 새 기준으로 만듭니다.';
        } else {
          _disposeLater([_edits.remove(id)!]);
        }
      }
      if (selectedCriterionId != null && !itemIds.contains(selectedCriterionId)) selectedCriterionId = null;
      selectedCriterionId ??= itemIds.isEmpty ? null : itemIds.first;
      final sel = selectedCriterionId;
      if (sel != null && !isLocal(sel)) unawaited(loadCriterionLinks(sel));
      for (final c in rows) {
        chat.criterionSaved(c);
      }
      final picked = chat.criterionId;
      if (picked != null && !ids.contains(picked)) chat.criterionRemoved(picked);
    } catch (e) {
      if (epoch != _epoch) return;
      final ex = ConceptLibraryException.from(e);
      loadError = ex.message;
      notReady = ex.notReady;
    } finally {
      if (epoch == _epoch) {
        loading = false;
        notifyListeners();
      }
    }
  }

  /// 같은 쪽 안에서 고른다(초점은 바꾸지 않는다).
  void selectCriterion(String id) {
    if (selectedCriterionId == id) return;
    selectedCriterionId = id;
    notifyListeners();
    if (!isLocal(id)) unawaited(loadCriterionLinks(id));
  }

  /// 요약에서 골랐을 때: 기준 쪽을 크게 보고 그 항목을 연다.
  void openCriterion(String id) {
    focus = ConceptWorkspaceFocus.criteria;
    narrowChat = false;
    if (selectedCriterionId != id) {
      selectedCriterionId = id;
      if (!isLocal(id)) unawaited(loadCriterionLinks(id));
    }
    notifyListeners();
  }

  String addCriterion() {
    _localSeq += 1;
    final id = 'new-$_localSeq';
    _localNew.add(id);
    _edits[id] = CriterionEdit('', '');
    selectedCriterionId = id;
    notifyListeners();
    return id;
  }

  void _replace(ConceptCriterion row) {
    criteria = [for (final c in criteria) c.id == row.id ? row : c];
    chat.criterionSaved(row);
  }

  void _removeLocal(String id) {
    final idx = itemIds.indexOf(id);
    _localNew.remove(id);
    final e = _edits.remove(id);
    if (e != null) _disposeLater([e]);
    errors.remove(id);
    if (selectedCriterionId == id) {
      final ids = itemIds;
      selectedCriterionId = ids.isEmpty ? null : ids[(idx - 1).clamp(0, ids.length - 1)];
    }
  }

  /// 초안 저장. 확정본은 그대로다. 실패하면 입력을 그대로 두고 errors에 이유를 남긴다.
  Future<bool> saveDraft(String id) async {
    final edit = _edits[id];
    if (edit == null || busyId != null) return false;
    final sentTitle = edit.title.text;
    final sentBody = edit.body.text;
    if (sentTitle.trim().isEmpty) {
      errors[id] = '제목을 입력하세요.';
      notifyListeners();
      return false;
    }
    final epoch = _epoch;
    busyId = id;
    errors.remove(id);
    notifyListeners();
    try {
      final ConceptCriterion row;
      if (isLocal(id)) {
        row = await _backend.createCriterion(title: sentTitle.trim(), body: sentBody);
        if (epoch != _epoch) return false;
        _localNew.remove(id);
        _edits.remove(id);
        _edits[row.id] = edit;
        errors.remove(id);
        criteria = [...criteria, row];
        _conceptsOfCriterion[row.id] = [];
        if (selectedCriterionId == id) selectedCriterionId = row.id;
      } else {
        final base = criterionById(id);
        if (base == null) return false;
        row = await _backend.saveDraft(base, title: sentTitle.trim(), body: sentBody);
        if (epoch != _epoch) return false;
        _replace(row);
      }
      final typedMeanwhile = edit.title.text != sentTitle || edit.body.text != sentBody;
      edit.rebase(row.savedTitle, row.savedBody, keepText: typedMeanwhile);
      return true;
    } catch (e) {
      if (epoch != _epoch) return false;
      final ex = ConceptLibraryException.from(e);
      errors[id] = ex.message;
      if (ex.stale || ex.code == 'concept_criteria_not_found') unawaited(loadCriteria());
      return false;
    } finally {
      if (epoch == _epoch) {
        busyId = null;
        notifyListeners();
      }
    }
  }

  /// 저장된 초안을 확정본으로 올린다. 저장 안 한 입력이 있으면 하지 않는다(보이는 글과 확정본이 달라지지 않게).
  Future<bool> confirm(String id, {String? note}) async {
    final base = criterionById(id);
    if (base == null || !base.hasDraft || isDirty(id) || busyId != null) return false;
    final epoch = _epoch;
    busyId = id;
    errors.remove(id);
    notifyListeners();
    try {
      final row = await _backend.confirm(base, note: note);
      if (epoch != _epoch) return false;
      _replace(row);
      _edits[id]?.rebase(row.savedTitle, row.savedBody);
      return true;
    } catch (e) {
      if (epoch != _epoch) return false;
      final ex = ConceptLibraryException.from(e);
      errors[id] = ex.message;
      if (ex.stale || ex.code == 'concept_criteria_not_found') unawaited(loadCriteria());
      return false;
    } finally {
      if (epoch == _epoch) {
        busyId = null;
        notifyListeners();
      }
    }
  }

  /// 저장된 초안을 버린다. 확정한 적 없는 항목은 항목째 지워진다. 새 항목(저장 전)은 그냥 뺀다.
  Future<bool> discardDraft(String id) async {
    if (isLocal(id)) {
      _removeLocal(id);
      notifyListeners();
      return true;
    }
    final base = criterionById(id);
    if (base == null || !base.hasDraft || busyId != null) return false;
    final epoch = _epoch;
    busyId = id;
    errors.remove(id);
    notifyListeners();
    try {
      final row = await _backend.discardDraft(base);
      if (epoch != _epoch) return false;
      if (row == null) {
        final idx = itemIds.indexOf(id);
        criteria = [
          for (final c in criteria)
            if (c.id != id) c
        ];
        final e = _edits.remove(id);
        if (e != null) _disposeLater([e]);
        _conceptsOfCriterion.remove(id);
        for (final entry in _criteriaOfConcept.entries) {
          entry.value.remove(id);
        }
        if (selectedCriterionId == id) {
          final ids = itemIds;
          selectedCriterionId = ids.isEmpty ? null : ids[(idx - 1).clamp(0, ids.length - 1)];
        }
        chat.criterionRemoved(id);
      } else {
        _replace(row);
        _edits[id]?.rebase(row.savedTitle, row.savedBody);
      }
      return true;
    } catch (e) {
      if (epoch != _epoch) return false;
      final ex = ConceptLibraryException.from(e);
      errors[id] = ex.message;
      if (ex.stale || ex.code == 'concept_criteria_not_found') unawaited(loadCriteria());
      return false;
    } finally {
      if (epoch == _epoch) {
        busyId = null;
        notifyListeners();
      }
    }
  }

  /// 입력을 마지막 저장값으로 되돌린다(서버에 보내지 않는다). 새 항목이면 뺀다.
  void cancelEdit(String id) {
    if (isLocal(id)) {
      _removeLocal(id);
      notifyListeners();
      return;
    }
    final c = criterionById(id);
    final e = _edits[id];
    if (c == null || e == null) return;
    e.rebase(c.savedTitle, c.savedBody);
    errors.remove(id);
    notifyListeners();
  }

  Future<List<ConceptCriterionRevision>> revisionsOf(String id) => _backend.listRevisions(id);

  /// 아직 없는 기본 틀(같은 제목이 없는 것).
  List<ConceptCriterionTemplate> get missingTemplates => [
        for (final t in kConceptCriterionTemplates)
          if (!criteria.any((c) => c.title == t.title || c.draftTitle == t.title)) t
      ];

  String? templateError;

  /// 기본 틀을 "기본 틀 초안"으로 만든다. 확정하지 않는다. 반환: 만든 수.
  Future<int> createTemplates() async {
    if (templateBusy) return 0;
    final epoch = _epoch;
    templateBusy = true;
    templateError = null;
    notifyListeners();
    var made = 0;
    try {
      for (final t in missingTemplates) {
        final row = await _backend.createCriterion(title: t.title, body: t.body, origin: 'template');
        if (epoch != _epoch) return made;
        criteria = [...criteria, row];
        _conceptsOfCriterion[row.id] = [];
        made += 1;
      }
      if (selectedCriterionId == null && criteria.isNotEmpty) selectedCriterionId = criteria.first.id;
    } catch (e) {
      if (epoch == _epoch) templateError = ConceptLibraryException.from(e).message;
    } finally {
      if (epoch == _epoch) {
        templateBusy = false;
        notifyListeners();
      }
    }
    return made;
  }

  // ------------------------------------------------------------------ 개념(정리 결과)
  ConceptItem? selectedConcept;

  /// 트리 표시용. 트리가 작업 공간의 모든 변경마다 다시 그려지지 않게 따로 둔다.
  final ValueNotifier<String?> openedConceptId = ValueNotifier<String?>(null);

  /// 서버에 저장된 개념(임시 칩이 아님). 연결·출처는 저장된 개념에만 붙는다.
  bool isSavedConcept(ConceptItem c) => ConceptChatController.isSavedConceptId(c.id);

  /// 같은 쪽 안에서 연다(초점은 바꾸지 않는다).
  void selectConcept(ConceptItem c) {
    final same = selectedConcept?.id == c.id;
    selectedConcept = c;
    openedConceptId.value = c.id;
    notifyListeners();
    if (!same && ConceptChatController.isSavedConceptId(c.id)) {
      unawaited(loadConceptLinks(c.id));
      unawaited(loadSources(c.id));
      unawaited(loadConceptType(c.id));
      unawaited(statements.load(c.id));
      unawaited(relations.load(c.id));
    }
  }

  /// 요약에서 골랐을 때: 라이브러리 쪽을 크게 보고 그 개념을 연다.
  void openConcept(ConceptItem c) {
    focus = ConceptWorkspaceFocus.library;
    narrowChat = false;
    selectConcept(c);
  }

  /// 다시 읽은 개념 중에 열어 둔 개념이 있으면 새 저장값으로 바꾼다. 없으면 그대로 둔다(다른 도메인일 수 있다).
  /// 지운 경우는 [conceptRemoved]로 닫는다.
  void syncSelectedConcept(Iterable<ConceptItem> fresh) {
    final id = selectedConcept?.id;
    if (id == null) return;
    for (final c in fresh) {
      if (c.id == id) {
        selectedConcept = c;
        notifyListeners();
        return;
      }
    }
  }

  void conceptRemoved(String id) {
    if (selectedConcept?.id == id) {
      selectedConcept = null;
      openedConceptId.value = null;
    }
    _criteriaOfConcept.remove(id);
    _sources.remove(id);
    statements.conceptRemoved(id);
    relations.conceptRemoved(id);
    for (final list in _conceptsOfCriterion.values) {
      list.removeWhere((c) => c.conceptId == id);
    }
    notifyListeners();
  }

  // ------------------------------------------------------------------ 기준–개념 연결(사용자가 직접 이은 것만)
  final Map<String, List<String>> _criteriaOfConcept = {};
  final Map<String, String> _criteriaOfConceptError = {};
  final Map<String, List<ConceptLinkedConcept>> _conceptsOfCriterion = {};
  final Map<String, String> _conceptsOfCriterionError = {};

  /// null = 아직 읽지 않았거나 읽지 못함([linkedCriteriaError]).
  List<String>? linkedCriteriaOf(String conceptId) => _criteriaOfConcept[conceptId];
  String? linkedCriteriaError(String conceptId) => _criteriaOfConceptError[conceptId];
  List<ConceptLinkedConcept>? linkedConceptsOf(String criterionId) => _conceptsOfCriterion[criterionId];
  String? linkedConceptsError(String criterionId) => _conceptsOfCriterionError[criterionId];

  Future<void> loadConceptLinks(String conceptId) async {
    final epoch = _epoch;
    try {
      final ids = await _backend.criterionIdsForConcept(conceptId);
      if (epoch != _epoch) return;
      _criteriaOfConcept[conceptId] = ids;
      _criteriaOfConceptError.remove(conceptId);
    } catch (e) {
      if (epoch != _epoch) return;
      _criteriaOfConcept.remove(conceptId);
      _criteriaOfConceptError[conceptId] = ConceptLibraryException.from(e).message;
    }
    notifyListeners();
  }

  Future<void> loadCriterionLinks(String criterionId) async {
    final epoch = _epoch;
    try {
      final list = await _backend.conceptsForCriterion(criterionId);
      if (epoch != _epoch) return;
      _conceptsOfCriterion[criterionId] = list;
      _conceptsOfCriterionError.remove(criterionId);
    } catch (e) {
      if (epoch != _epoch) return;
      _conceptsOfCriterion.remove(criterionId);
      _conceptsOfCriterionError[criterionId] = ConceptLibraryException.from(e).message;
    }
    notifyListeners();
  }

  /// 사용자가 누를 때만 잇는다. 반환: 실패 이유(성공이면 null).
  Future<String?> link(String criterionId, ConceptItem concept) async {
    if (isLocal(criterionId)) return '먼저 기준 초안을 저장하세요.';
    if (!ConceptChatController.isSavedConceptId(concept.id)) return '저장된 개념만 이을 수 있습니다.';
    final epoch = _epoch;
    try {
      await _backend.link(criterionId: criterionId, conceptId: concept.id);
      if (epoch != _epoch) return null;
      final ids = _criteriaOfConcept[concept.id];
      if (ids != null && !ids.contains(criterionId)) ids.add(criterionId);
      final list = _conceptsOfCriterion[criterionId];
      if (list != null && !list.any((c) => c.conceptId == concept.id)) {
        list.add(ConceptLinkedConcept(conceptId: concept.id, name: concept.name, kind: concept.kind));
      }
      notifyListeners();
      return null;
    } catch (e) {
      return ConceptLibraryException.from(e).message;
    }
  }

  Future<String?> unlink(String criterionId, String conceptId) async {
    final epoch = _epoch;
    try {
      await _backend.unlink(criterionId: criterionId, conceptId: conceptId);
      if (epoch != _epoch) return null;
      _criteriaOfConcept[conceptId]?.remove(criterionId);
      _conceptsOfCriterion[criterionId]?.removeWhere((c) => c.conceptId == conceptId);
      notifyListeners();
      return null;
    } catch (e) {
      return ConceptLibraryException.from(e).message;
    }
  }

  // ------------------------------------------------------------------ 개념 출처(교재 쪽)
  final Map<String, List<ConceptSourceRef>> _sources = {};
  final Map<String, String> _sourcesError = {};

  List<ConceptSourceRef>? sourcesOf(String conceptId) => _sources[conceptId];
  String? sourcesError(String conceptId) => _sourcesError[conceptId];

  // ------------------------------------------------------------------ 개념 유형(초안 확정 때 붙은 것)
  final Map<String, String?> _types = {};
  final Set<String> _typesFailed = {};

  /// 읽은 적 없으면 키가 없다. 읽었는데 유형이 없으면 null.
  bool conceptTypeLoaded(String conceptId) => _types.containsKey(conceptId);
  String? conceptTypeOf(String conceptId) => _types[conceptId];
  bool conceptTypeFailed(String conceptId) => _typesFailed.contains(conceptId);

  Future<void> loadConceptType(String conceptId) async {
    final epoch = _epoch;
    try {
      final name = await _backend.conceptTypeName(conceptId);
      if (epoch != _epoch) return;
      _types[conceptId] = name;
      _typesFailed.remove(conceptId);
    } catch (_) {
      if (epoch != _epoch) return;
      _types.remove(conceptId);
      _typesFailed.add(conceptId);
    }
    notifyListeners();
  }

  Future<void> loadSources(String conceptId) async {
    final epoch = _epoch;
    try {
      final list = await _backend.sourcesFor(conceptId);
      if (epoch != _epoch) return;
      _sources[conceptId] = list;
      _sourcesError.remove(conceptId);
    } catch (e) {
      if (epoch != _epoch) return;
      _sources.remove(conceptId);
      _sourcesError[conceptId] = ConceptLibraryException.from(e).message;
    }
    notifyListeners();
  }

  /// 개념책 창에서 사용자가 고른 쪽을 출처로 잇는다. 책·쪽은 저장된 교재 구조에서 온 값만 쓴다.
  Future<String?> addSource({
    required ConceptItem concept,
    required String academyId,
    required String bookId,
    required String gradeLabel,
    required int rawPage,
    int? displayPage,
    List<String> unitPath = const [],
  }) async {
    if (!ConceptChatController.isSavedConceptId(concept.id)) return '저장된 개념에만 출처를 이을 수 있습니다.';
    final epoch = _epoch;
    try {
      final row = await _backend.addSource(
        conceptId: concept.id,
        academyId: academyId,
        bookId: bookId,
        gradeLabel: gradeLabel,
        rawPage: rawPage,
        displayPage: displayPage,
        unitPath: unitPath,
      );
      if (epoch != _epoch) return null;
      final list = _sources[concept.id];
      if (list != null) {
        list.add(row);
        notifyListeners();
      } else {
        unawaited(loadSources(concept.id));
      }
      return null;
    } catch (e) {
      return ConceptLibraryException.from(e).message;
    }
  }

  Future<String?> removeSource(ConceptSourceRef s) async {
    final epoch = _epoch;
    try {
      await _backend.removeSource(s.id);
      if (epoch != _epoch) return null;
      _sources[s.conceptId]?.removeWhere((x) => x.id == s.id);
      notifyListeners();
      return null;
    } catch (e) {
      return ConceptLibraryException.from(e).message;
    }
  }
}
