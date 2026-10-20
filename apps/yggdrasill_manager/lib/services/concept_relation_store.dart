import 'package:flutter/foundation.dart';

import 'concept_relation_service.dart';

/// 개념 상세에서 보는 관계·검토 필요 표시와, 트리에 붙일 "검토 필요" 개념. 쓰기는 [ConceptRelationBackend]로만 한다.
class ConceptRelationStore extends ChangeNotifier {
  ConceptRelationStore(this._backendFactory);

  final ConceptRelationBackend Function() _backendFactory;
  ConceptRelationBackend? _backendCache;
  ConceptRelationBackend get backend => _backendCache ??= _backendFactory();

  int _epoch = 0;

  final Map<String, List<ConceptRelation>> _relations = {};
  final Map<String, List<ConceptReview>> _reviews = {};
  final Map<String, ConceptPick> _picks = {};
  final Map<String, String> _errors = {};

  /// 열린 검토 표시가 붙은 개념. 읽지 못했으면 비어 있다.
  Set<String> _open = {};

  /// DB에 관계 표가 아직 없다(마이그레이션 반영 전).
  bool notReady = false;
  bool busy = false;

  /// [_open]이 바뀌면 오른다. 트리는 이것만 듣는다.
  final ValueNotifier<int> openTick = ValueNotifier<int>(0);

  void reset() {
    _epoch += 1;
    _relations.clear();
    _reviews.clear();
    _picks.clear();
    _errors.clear();
    _open = {};
    notReady = false;
    busy = false;
    openTick.value += 1;
    notifyListeners();
  }

  bool loaded(String conceptId) => _relations.containsKey(conceptId) && _reviews.containsKey(conceptId);
  String? errorOf(String conceptId) => _errors[conceptId];

  List<ConceptRelation> relationsOf(String conceptId) => _relations[conceptId] ?? const [];
  List<ConceptReview> reviewsOf(String conceptId) => _reviews[conceptId] ?? const [];
  List<ConceptReview> openReviewsOf(String conceptId) => [
        for (final r in reviewsOf(conceptId))
          if (r.open) r
      ];
  List<ConceptReview> closedReviewsOf(String conceptId) => [
        for (final r in reviewsOf(conceptId))
          if (!r.open) r
      ];
  ConceptPick? pickOf(String? id) => id == null ? null : _picks[id];

  /// 트리 표시: 이 개념에 열린 검토 표시가 있다.
  bool reviewOpen(String conceptId) => _open.contains(conceptId);

  void rememberPick(ConceptPick p) => _picks[p.id] = p;

  Future<void> loadOpen() async {
    final epoch = _epoch;
    try {
      final ids = await backend.openReviewConceptIds();
      if (epoch != _epoch) return;
      _open = ids;
      notReady = false;
    } catch (e) {
      if (epoch != _epoch) return;
      notReady = ConceptRelationException.from(e).notReady;
      _open = {};
    }
    openTick.value += 1;
    notifyListeners();
  }

  Future<void> load(String conceptId) async {
    final epoch = _epoch;
    try {
      final results = await Future.wait([backend.relationsFor(conceptId), backend.reviewsFor(conceptId)]);
      if (epoch != _epoch) return;
      final relations = results[0] as List<ConceptRelation>;
      final reviews = results[1] as List<ConceptReview>;
      final ids = <String>{
        for (final r in relations) ...[r.conceptId, r.relatedId],
        for (final v in reviews) ...[v.conceptId, if (v.otherId != null) v.otherId!],
      }..removeWhere(_picks.containsKey);
      if (ids.isNotEmpty) {
        final picks = await backend.picks(ids);
        if (epoch != _epoch) return;
        _picks.addAll(picks);
      }
      _relations[conceptId] = relations;
      _reviews[conceptId] = reviews;
      _errors.remove(conceptId);
      notReady = false;
      final open = reviews.any((v) => v.open && v.conceptId == conceptId);
      if (open != _open.contains(conceptId)) {
        _open = {..._open};
        open ? _open.add(conceptId) : _open.remove(conceptId);
        openTick.value += 1;
      }
    } catch (e) {
      if (epoch != _epoch) return;
      final ex = ConceptRelationException.from(e);
      notReady = ex.notReady;
      _errors[conceptId] = ex.message;
    }
    notifyListeners();
  }

  void conceptRemoved(String conceptId) {
    _relations.remove(conceptId);
    _reviews.remove(conceptId);
    _errors.remove(conceptId);
    if (_open.contains(conceptId)) {
      _open = {..._open}..remove(conceptId);
      openTick.value += 1;
    }
    for (final id in _relations.keys.toList()) {
      if (_relations[id]!.any((r) => r.conceptId == conceptId || r.relatedId == conceptId)) {
        _relations.remove(id);
        _reviews.remove(id);
      }
    }
  }

  /// 보내고, 성공하면 [touched] 개념을 다시 읽는다. 실패하면 이유를 돌려준다.
  Future<String?> _run(Iterable<String> touched, Future<void> Function() send) async {
    if (busy) return '앞 작업이 끝난 뒤 다시 해 주세요.';
    final epoch = _epoch;
    busy = true;
    notifyListeners();
    String? err;
    try {
      await send();
    } catch (e) {
      err = ConceptRelationException.from(e).message;
    }
    if (epoch != _epoch) return null;
    busy = false;
    final ids = touched.toSet();
    for (final id in ids) {
      if (_relations.containsKey(id) || _errors.containsKey(id)) await load(id);
    }
    await loadOpen();
    return err;
  }

  Future<String?> setRelation({
    required String conceptId,
    required String relatedId,
    required ConceptRelationKind kind,
    String? note,
  }) =>
      _run([conceptId, relatedId],
          () => backend.setRelation(conceptId: conceptId, relatedId: relatedId, kind: kind, note: note));

  Future<String?> removeRelation(ConceptRelation r) =>
      _run([r.conceptId, r.relatedId], () => backend.removeRelation(r.id));

  Future<String?> openReview({required String conceptId, String? otherId, String? note}) => _run(
      [conceptId, if (otherId != null) otherId],
      () => backend.openReview(conceptId: conceptId, otherId: otherId, note: note));

  Future<String?> resolveReview(
    ConceptReview review,
    ConceptReviewResolution resolution, {
    String? otherId,
    String? note,
    bool reverse = false,
  }) =>
      _run([review.conceptId, if (review.otherId != null) review.otherId!, if (otherId != null) otherId],
          () => backend.resolveReview(review.id, resolution, otherId: otherId, note: note, reverse: reverse));

  Future<String?> decidePair({
    required String conceptId,
    required String otherId,
    required ConceptReviewResolution resolution,
    String? note,
  }) =>
      _run([conceptId, otherId],
          () => backend.decidePair(conceptId: conceptId, otherId: otherId, resolution: resolution, note: note));

  @override
  void dispose() {
    openTick.dispose();
    super.dispose();
  }
}
