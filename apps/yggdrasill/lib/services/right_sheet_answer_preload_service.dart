import 'dart:async';

import '../app_overlays.dart';
import '../widgets/pdf/homework_answer_viewer_dialog.dart';
import 'learning_problem_bank_service.dart';

class RightSheetPreloadedPdfLinks {
  final String answerPath;
  final String solutionPath;

  const RightSheetPreloadedPdfLinks({
    required this.answerPath,
    required this.solutionPath,
  });
}

class RightSheetPreloadedSessionPayload {
  final String sessionId;
  final String homeworkId;
  final String title;
  final String studentName;
  final String groupHomeworkTitle;
  final String assignmentCode;
  final List<HomeworkAnswerGradingPage> gradingPages;
  final Map<String, double> scoreByQuestionKey;
  final List<Map<String, String>> overlayEntries;
  final String answerPathRaw;
  final String solutionPathRaw;
  final String answerViewerCacheKey;

  const RightSheetPreloadedSessionPayload({
    required this.sessionId,
    required this.homeworkId,
    required this.title,
    required this.studentName,
    required this.groupHomeworkTitle,
    required this.assignmentCode,
    required this.gradingPages,
    this.scoreByQuestionKey = const <String, double>{},
    this.overlayEntries = const <Map<String, String>>[],
    this.answerPathRaw = '',
    this.solutionPathRaw = '',
    this.answerViewerCacheKey = '',
  });
}

class _TimedValue<T> {
  final T value;
  final DateTime expiresAt;

  const _TimedValue({
    required this.value,
    required this.expiresAt,
  });

  bool get isFresh => DateTime.now().isBefore(expiresAt);
}

class RightSheetAnswerPreloadService {
  RightSheetAnswerPreloadService._();

  static final RightSheetAnswerPreloadService instance =
      RightSheetAnswerPreloadService._();

  static const Duration _ttl = Duration(minutes: 20);
  static const Duration _failureBackoff = Duration(minutes: 2);
  static const int _maxCacheEntries = 800;

  final LearningProblemBankService _problemBankService =
      LearningProblemBankService();
  final Map<String, _TimedValue<LearningProblemAnswerRender>> _assetCache =
      <String, _TimedValue<LearningProblemAnswerRender>>{};
  final Map<String, DateTime> _assetFailureUntil = <String, DateTime>{};
  final Map<String, _TimedValue<RightSheetPreloadedPdfLinks>> _pdfCache =
      <String, _TimedValue<RightSheetPreloadedPdfLinks>>{};
  final Map<String, _TimedValue<RightSheetPreloadedSessionPayload>>
      _sessionCache =
      <String, _TimedValue<RightSheetPreloadedSessionPayload>>{};
  final Map<String, Future<Map<String, LearningProblemAnswerRender>>>
      _assetInflight =
      <String, Future<Map<String, LearningProblemAnswerRender>>>{};

  Future<void> _queue = Future<void>.value();

  String _assetKey({
    required String academyId,
    required String sourceKind,
    required String sourceId,
    required String answerKind,
    required String styleVersion,
  }) {
    return '${academyId.trim()}|${sourceKind.trim()}|${answerKind.trim()}|${styleVersion.trim()}|${sourceId.trim()}';
  }

  String _requestKey({
    required String academyId,
    required String sourceKind,
    required String answerKind,
    required Iterable<String> sourceIds,
    required String styleVersion,
  }) {
    final ids = sourceIds
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList()
      ..sort();
    return '${academyId.trim()}|${sourceKind.trim()}|${answerKind.trim()}|${styleVersion.trim()}|${ids.join(',')}';
  }

  String _normalizeAnswerRenderKind(String raw) {
    final kind = raw.trim().toLowerCase();
    if (kind == 'essay' || kind.contains('서술')) return 'essay';
    if (kind == 'subjective' || kind.contains('주관')) return 'subjective';
    return 'subjective';
  }

  String _answerRenderKindForRawCell(Map rawCell) {
    final explicit =
        '${rawCell['answerRenderKind'] ?? rawCell['answer_render_kind'] ?? rawCell['answerRenderPolicy'] ?? rawCell['answer_render_policy'] ?? rawCell['answerKind'] ?? rawCell['answer_kind'] ?? ''}'
            .trim();
    if (explicit.isNotEmpty) return _normalizeAnswerRenderKind(explicit);
    final answerMode = '${rawCell['answerMode'] ?? rawCell['mode'] ?? ''}';
    return _normalizeAnswerRenderKind(answerMode);
  }

  void _pruneIfNeeded() {
    final now = DateTime.now();
    _assetCache.removeWhere((_, entry) => now.isAfter(entry.expiresAt));
    _pdfCache.removeWhere((_, entry) => now.isAfter(entry.expiresAt));
    _sessionCache.removeWhere((_, entry) => now.isAfter(entry.expiresAt));
    _assetFailureUntil.removeWhere((_, expiresAt) => now.isAfter(expiresAt));
    while (_assetCache.length > _maxCacheEntries) {
      _assetCache.remove(_assetCache.keys.first);
    }
  }

  Future<Map<String, LearningProblemAnswerRender>>
      loadUnifiedAnswerRenderAssets({
    required String academyId,
    required String sourceKind,
    required Iterable<String> sourceIds,
    String answerKind = 'subjective',
    String styleVersion = kUnifiedAnswerRenderStyleVersion,
    List<String> fallbackStyleVersions = const <String>[],
    // 세트형(파트 렌더가 있어야 하는) source id 목록. 본체 렌더만 캐시된 채
    // 파트가 비어 있으면 짧은 backoff 후 재조회해 백그라운드 v11 파트 생성
    // 결과를 다시 가져온다.
    Set<String> partExpectedSourceIds = const <String>{},
  }) async {
    final safeAcademyId = academyId.trim();
    final safeSourceKind = sourceKind.trim();
    final safeAnswerKind = _normalizeAnswerRenderKind(answerKind);
    final ids = sourceIds
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (safeAcademyId.isEmpty || safeSourceKind.isEmpty || ids.isEmpty) {
      return const <String, LearningProblemAnswerRender>{};
    }
    _pruneIfNeeded();

    // v11 파일럿은 세트형 파트 렌더('id#(1)' 키)가 함께 내려온다.
    final expectParts = styleVersion == kUnifiedAnswerRenderStyleVersionV11;
    final now = DateTime.now();
    final out = <String, LearningProblemAnswerRender>{};
    final missing = <String>[];
    for (final id in ids) {
      final key = _assetKey(
        academyId: safeAcademyId,
        sourceKind: safeSourceKind,
        sourceId: id,
        answerKind: safeAnswerKind,
        styleVersion: styleVersion,
      );
      final cached = _assetCache[key];
      final failureUntil = _assetFailureUntil[key];
      final inBackoff = failureUntil != null && now.isBefore(failureUntil);
      if (cached != null && cached.isFresh) {
        var anyPartCached = false;
        if (expectParts) {
          for (var p = 1; p <= 12; p++) {
            final partId = '$id#($p)';
            final cachedPart = _assetCache[_assetKey(
              academyId: safeAcademyId,
              sourceKind: safeSourceKind,
              sourceId: partId,
              answerKind: safeAnswerKind,
              styleVersion: styleVersion,
            )];
            if (cachedPart != null && cachedPart.isFresh) {
              out[partId] = cachedPart.value;
              anyPartCached = true;
            }
          }
        }
        // 세트형인데 파트 렌더가 캐시에 없다 — 본체 캐시가 살아 있어도
        // (backoff 가 끝났으면) 재조회해 파트를 다시 찾는다.
        if (expectParts &&
            partExpectedSourceIds.contains(id) &&
            !anyPartCached &&
            !inBackoff) {
          missing.add(id);
        }
        out[id] = cached.value;
        continue;
      }
      if (inBackoff) {
        continue;
      }
      missing.add(id);
    }
    if (missing.isEmpty) return out;

    final requestKey = _requestKey(
      academyId: safeAcademyId,
      sourceKind: safeSourceKind,
      answerKind: safeAnswerKind,
      sourceIds: missing,
      styleVersion: styleVersion,
    );
    final fetched = await _assetInflight.putIfAbsent(requestKey, () async {
      try {
        return await _problemBankService.loadUnifiedAnswerRenderAssets(
          academyId: safeAcademyId,
          sourceKind: safeSourceKind,
          sourceIds: missing,
          answerKind: safeAnswerKind,
          styleVersion: styleVersion,
          fallbackStyleVersions: fallbackStyleVersions,
        );
      } finally {
        scheduleMicrotask(() => _assetInflight.remove(requestKey));
      }
    });

    final expiresAt = DateTime.now().add(_ttl);
    final failureExpiresAt = DateTime.now().add(_failureBackoff);
    for (final id in missing) {
      final render = fetched[id];
      final key = _assetKey(
        academyId: safeAcademyId,
        sourceKind: safeSourceKind,
        sourceId: id,
        answerKind: safeAnswerKind,
        styleVersion: styleVersion,
      );
      if (render != null && render.hasImage) {
        // v11 요청에 v10 폴백이 내려온 경우 짧게만 캐시한다 — 서버가
        // 백그라운드에서 v11 을 생성하므로 곧 갱신된 렌더를 받아야 한다.
        final isStaleStyleFallback =
            expectParts && render.styleVersion != styleVersion;
        _assetCache[key] = _TimedValue(
          value: render,
          expiresAt: isStaleStyleFallback ? failureExpiresAt : expiresAt,
        );
        // 세트형인데 이번 응답에도 파트 렌더가 없으면 backoff 를 걸어
        // 다음 로드에서 재조회하도록 남겨둔다.
        final partsStillMissing = expectParts &&
            partExpectedSourceIds.contains(id) &&
            !fetched.keys.any((k) => k.startsWith('$id#'));
        if (partsStillMissing) {
          _assetFailureUntil[key] = failureExpiresAt;
        } else {
          _assetFailureUntil.remove(key);
        }
        out[id] = render;
      } else {
        _assetFailureUntil[key] = failureExpiresAt;
      }
    }
    // 파트 렌더 엔트리('id#(1)')는 요청 id 목록에 없어도 캐시하고 결과에 포함.
    for (final entry in fetched.entries) {
      if (!entry.key.contains('#')) continue;
      if (!entry.value.hasImage) continue;
      final key = _assetKey(
        academyId: safeAcademyId,
        sourceKind: safeSourceKind,
        sourceId: entry.key,
        answerKind: safeAnswerKind,
        styleVersion: styleVersion,
      );
      _assetCache[key] = _TimedValue(value: entry.value, expiresAt: expiresAt);
      out[entry.key] = entry.value;
    }
    _pruneIfNeeded();
    return out;
  }

  void putPdfLinks({
    required String cacheKey,
    required String answerPath,
    String solutionPath = '',
  }) {
    final safeKey = cacheKey.trim();
    final safeAnswer = answerPath.trim();
    if (safeKey.isEmpty || safeAnswer.isEmpty) return;
    _pdfCache[safeKey] = _TimedValue(
      value: RightSheetPreloadedPdfLinks(
        answerPath: safeAnswer,
        solutionPath: solutionPath.trim(),
      ),
      expiresAt: DateTime.now().add(_ttl),
    );
    _pruneIfNeeded();
  }

  RightSheetPreloadedPdfLinks? getPdfLinks(String cacheKey) {
    final safeKey = cacheKey.trim();
    if (safeKey.isEmpty) return null;
    final entry = _pdfCache[safeKey];
    if (entry == null) return null;
    if (entry.isFresh) return entry.value;
    _pdfCache.remove(safeKey);
    return null;
  }

  void putSessionPayload({
    required String cacheKey,
    required RightSheetPreloadedSessionPayload payload,
  }) {
    final safeKey = cacheKey.trim();
    if (safeKey.isEmpty || payload.homeworkId.trim().isEmpty) return;
    _sessionCache[safeKey] = _TimedValue(
      value: payload,
      expiresAt: DateTime.now().add(_ttl),
    );
    _pruneIfNeeded();
  }

  RightSheetPreloadedSessionPayload? getSessionPayload(String cacheKey) {
    final safeKey = cacheKey.trim();
    if (safeKey.isEmpty) return null;
    final entry = _sessionCache[safeKey];
    if (entry == null) return null;
    if (entry.isFresh) return entry.value;
    _sessionCache.remove(safeKey);
    return null;
  }

  void schedulePreloadSessions({
    required String academyId,
    required Iterable<RightSideSheetTestGradingSession> sessions,
    int maxAssignments = 10,
    int maxQuestionsPerAssignment = 60,
  }) {
    final selected = sessions
        .where((session) => session.sessionId.trim().isNotEmpty)
        .take(maxAssignments)
        .toList(growable: false);
    if (selected.isEmpty) return;
    _queue = _queue.catchError((_) {}).then((_) async {
      for (final session in selected) {
        await preloadSessionRenderAssets(
          academyId: academyId,
          session: session,
          maxQuestions: maxQuestionsPerAssignment,
        );
      }
    });
  }

  Future<void> preloadSessionRenderAssets({
    required String academyId,
    required RightSideSheetTestGradingSession session,
    int maxQuestions = 60,
  }) async {
    final sourceIdsByLookup = <String, Set<String>>{};
    var scanned = 0;
    for (final rawPage in session.gradingPages) {
      final rawCells = rawPage['cells'];
      if (rawCells is! List) continue;
      for (final rawCell in rawCells) {
        if (rawCell is! Map) continue;
        if (scanned >= maxQuestions) break;
        scanned += 1;
        final answer = '${rawCell['answer'] ?? ''}'.trim();
        final answerMode = '${rawCell['answerMode'] ?? rawCell['mode'] ?? ''}'
            .trim()
            .toLowerCase();
        if (_isObjectiveAnswer(answer: answer, answerMode: answerMode)) {
          continue;
        }
        final assetKind =
            '${rawCell['answerAssetKind'] ?? rawCell['answer_asset_kind'] ?? ''}'
                .trim()
                .toLowerCase();
        final answerImageUrl =
            '${rawCell['answerImageUrl'] ?? rawCell['answer_image_url'] ?? ''}'
                .trim();
        if (assetKind == 'raw_answer_image' && answerImageUrl.isNotEmpty) {
          continue;
        }
        final sourceKind =
            '${rawCell['answerSourceKind'] ?? rawCell['answer_source_kind'] ?? rawCell['sourceKind'] ?? rawCell['source_kind'] ?? ''}'
                .trim()
                .toLowerCase();
        final sourceId =
            '${rawCell['answerSourceId'] ?? rawCell['answer_source_id'] ?? rawCell['sourceId'] ?? rawCell['source_id'] ?? ''}'
                .trim();
        if (sourceKind.isEmpty || sourceId.isEmpty) continue;
        final answerKind = _answerRenderKindForRawCell(rawCell);
        sourceIdsByLookup
            .putIfAbsent('$sourceKind\n$answerKind', () => <String>{})
            .add(sourceId);
      }
      if (scanned >= maxQuestions) break;
    }
    for (final entry in sourceIdsByLookup.entries) {
      final parts = entry.key.split('\n');
      if (parts.length != 2) continue;
      await loadUnifiedAnswerRenderAssets(
        academyId: academyId,
        sourceKind: parts[0],
        answerKind: parts[1],
        sourceIds: entry.value,
      );
    }
  }

  bool _isObjectiveAnswer(
      {required String answer, required String answerMode}) {
    if (answerMode == 'objective' || answerMode == 'choice') return true;
    return RegExp(r'^[①②③④⑤⑥⑦⑧⑨⑩,\s]+$').hasMatch(answer.trim());
  }
}
