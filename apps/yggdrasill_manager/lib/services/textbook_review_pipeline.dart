import 'dart:async';

import 'textbook_problem_review_service.dart';

/// 검수 파이프라인 한 번의 결과 요약.
class TextbookReviewPipelineSummary {
  const TextbookReviewPipelineSummary({
    required this.total,
    required this.reviewed,
    required this.renderChecked,
    required this.mathApproved,
    required this.qualityApproved,
    required this.notes,
    required this.errors,
  });

  final int total;
  final int reviewed;
  final int renderChecked;
  final int mathApproved;
  final int qualityApproved;
  final List<String> notes;
  final List<String> errors;
}

/// 문항검수 화면 없이 도는 소단원 검수 파이프라인. 화면의 `중단원 문항 검수 실행`과 같은 순서다.
///
/// AI 선풀이·원본 해설 전사·학생 시점 품질 검수 → V2 정답·해설 카드 렌더 검수 → 깨끗한 문항 승인·렌더 엔진 문제 보류
/// → 원본·해설 PDF 대조 수정안 → 정답·본문·그림 수정 반영 → 바뀐 문항만 V2 재렌더·원본 재대조 → 승인.
class TextbookReviewPipeline {
  TextbookReviewPipeline({
    required this.service,
    required this.scope,
    required this.matches,
    this.onProgress,
    this.isCancelled,
  });

  static const int _reviewChunkSize = 6;
  static const int _renderCheckChunkSize = 4;
  static const int _renderCheckParallel = 3;
  static const int _fixChunkSize = 3;

  final TextbookProblemReviewService service;
  final TextbookReviewUnitScope scope;
  final bool Function(TextbookProblemReviewItem item) matches;
  final void Function(String message)? onProgress;
  final bool Function()? isCancelled;

  /// 중단원 전체 문항(세트 머리·인접 해설 쪽 추론용)
  List<TextbookProblemReviewItem> allItems = const [];

  /// 이 소단원 문항
  List<TextbookProblemReviewItem> items = const [];
  Map<String, String> previewUrls = const {};
  final List<String> errors = [];
  final Map<String, String> _cardUrls = {};
  final Map<String, String> _mathResolvedSig = {};

  bool get _stopped => isCancelled?.call() ?? false;
  void _say(String message) => onProgress?.call(message);

  Future<void> reload() async {
    final fetched = await service.fetchUnitItems(scope);
    allItems = [...fetched]..sort(compareItemsByPageAndNumber);
    items = [for (final it in allItems) if (matches(it)) it];
  }

  Future<void> loadPreviews(List<TextbookProblemReviewItem> targets, {bool merge = true}) async {
    if (targets.isEmpty) return;
    final urls = await service.fetchEnginePreviewUrls(academyId: scope.academyId, items: targets);
    previewUrls = merge ? {...previewUrls, ...urls} : urls;
  }

  /// [forceRenderCheck]: 렌더 엔진을 고친 뒤처럼 이미 렌더 검수한 문항도 V2 를 다시 찍어 대조한다.
  Future<TextbookReviewPipelineSummary> runAll({bool forceRerun = false, bool forceRenderCheck = false}) async {
    final notes = <String>[];
    var mathApproved = 0;
    var qualityApproved = 0;
    var renderChecked = 0;
    await reload();
    if (items.isEmpty) {
      return TextbookReviewPipelineSummary(
        total: 0,
        reviewed: 0,
        renderChecked: 0,
        mathApproved: 0,
        qualityApproved: 0,
        notes: notes,
        errors: errors,
      );
    }
    _say('원본 PDF 준비');
    await service.ensureSourcePdfs(scope, items, onProgress: _say);
    _say('V2 문항 카드 준비 (${items.length}문항)');
    await loadPreviews(items, merge: false);
    final reviewed = await _reviewRounds(forceRerun: forceRerun);
    final withSolutionFigures = _stopped ? const <String>{} : await _solutionFiguresPass();

    if (!_stopped && service.hasGateway) {
      // 지난 검수에서 남은 렌더 이상 판정도 지금 카드로 다시 받는다(그 뒤 데이터가 고쳐졌을 수 있다).
      renderChecked = await _renderCheckPass(
        only: forceRenderCheck
            ? items
            : [
                for (final x in items)
                  if (x.needsRenderCheck || withSolutionFigures.contains(x.cropId) || x.renderBlocksReady) x,
              ],
      );
      // 방금 렌더 검수가 해설 그림 누락을 잡은 문항은 그림을 찾아 붙이고 바로 다시 대조한다.
      if (!_stopped && items.any((x) => x.needsSolutionFigures)) {
        final more = await _solutionFiguresPass();
        if (!_stopped && more.isNotEmpty) {
          renderChecked += await _renderCheckPass(only: [for (final x in items) if (more.contains(x.cropId)) x]);
        }
      }
    }

    if (!_stopped) {
      final cleanMath = [for (final x in items) if (x.mathStatus == 'clean') x.cropId];
      if (cleanMath.isNotEmpty) mathApproved += await service.approveAxis(cleanMath, 'math');
      final cleanQual = [for (final x in items) if (x.qualityStatus == 'clean' && !x.hasFigures) x.cropId];
      if (cleanQual.isNotEmpty) qualityApproved += await service.approveAxis(cleanQual, 'quality');
      final engineOnly = [
        for (final x in items)
          if (x.aiSuspectsEngine && !x.hasFigures && !x.commonStemDuplicated && !x.hasPendingFixProposal) x.cropId,
      ];
      if (engineOnly.isNotEmpty) await service.setEngineHold(engineOnly, hold: true);
      await reload();

      final fixTargets = [
        for (final x in items)
          if (!x.isEngineHeld &&
              x.canRenderOriginal &&
              (x.needsFixPass || x.mathStatus == 'issue' || x.qualityStatus == 'issue' || (x.hasFigures && x.fixPassAt == null)))
            x,
      ];
      if (fixTargets.isNotEmpty) {
        await _fixPass(fixTargets);
        await reload();
      }
    }

    if (!_stopped) {
      final appliedMath = await _bulkMathFixes(notes);
      await reload();
      final ids = <String>{
        for (final it in items)
          if (it.mathStatus == 'clean' || (it.mathStatus == 'approved' && it.pbAnswerDiffers)) it.cropId,
        ...appliedMath,
      }.toList();
      if (ids.isNotEmpty) mathApproved += await service.approveAxis(ids, 'math');
    }

    if (!_stopped) {
      final appliedQual = await _bulkQualityFixes(notes);
      await reload();
      final ids = <String>{
        for (final it in items)
          if (!it.isEngineHeld && it.qualityStatus == 'clean') it.cropId,
        ...appliedQual,
      }.toList();
      if (ids.isNotEmpty) qualityApproved += await service.approveAxis(ids, 'quality');
      await reload();
    }

    // 일괄 수정에서 정답·해설이 바뀐 문항은 DB 가 렌더 검수 시각을 지우므로 바뀐 카드로 다시 대조한다.
    if (!_stopped && service.hasGateway) {
      final stale = [for (final x in items) if (x.needsRenderCheck) x];
      if (stale.isNotEmpty) {
        await loadPreviews(stale);
        renderChecked += await _renderCheckPass(only: stale);
      }
    }

    return TextbookReviewPipelineSummary(
      total: items.length,
      reviewed: reviewed,
      renderChecked: renderChecked,
      mathApproved: mathApproved,
      qualityApproved: qualityApproved,
      notes: notes,
      errors: errors,
    );
  }

  /// AI 선풀이·원본 해설 전사·학생 시점 품질 검수. 같은 실행에서 이미 보낸 문항은 다시 고르지 않는다.
  Future<int> _reviewRounds({required bool forceRerun}) async {
    var total = 0;
    final sent = <String>{};
    for (var round = 0; round < 60; round += 1) {
      if (_stopped) break;
      final todo = [
        for (final x in (forceRerun ? items : items.where((x) => x.isReviewTodo)))
          if (!sent.contains(x.cropId)) x,
      ];
      if (todo.isEmpty) break;
      final chunks = [
        todo.take(_reviewChunkSize).toList(),
        if (todo.length > _reviewChunkSize) todo.skip(_reviewChunkSize).take(_reviewChunkSize).toList(),
      ];
      for (final c in chunks) {
        sent.addAll(c.map((x) => x.cropId));
      }
      _say('AI 풀이·해설 전사·품질 검수 ${items.length - todo.length}/${items.length}');
      final results = await Future.wait([
        for (final chunk in chunks)
          () async {
            try {
              final images = await service.prepareChunkImages(
                scope: scope,
                items: chunk,
                previewUrlsByCropId: previewUrls,
              );
              if (_stopped) return const <String, dynamic>{};
              return await service.runReviewChunk(
                scope,
                chunkSize: chunk.length,
                forceRerun: forceRerun,
                cropIds: [for (final x in chunk) x.cropId],
                images: images,
              );
            } catch (e) {
              errors.add('${chunk.map((x) => x.problemNumber).join(',')}번 검수: $e');
              return const <String, dynamic>{};
            }
          }(),
      ]);
      var processed = 0;
      for (final r in results) {
        processed += (r['processed'] as num?)?.toInt() ?? 0;
      }
      total += processed;
      await reload();
      if (processed <= 0) break;
    }
    return total;
  }

  /// 원본 해설에 그림이 있을 수 있는 문항만 해설 PDF 에서 그림을 찾아 잘라 붙인다. 반환: 그림이 붙은 crop_id.
  Future<Set<String>> _solutionFiguresPass() async {
    final targets = [for (final x in items) if (x.needsSolutionFigures) x];
    if (targets.isEmpty) return const {};
    _say('해설 그림 찾기 0/${targets.length}');
    final res = await service.extractSolutionFigures(
      scope,
      targets,
      onProgress: (done, total) => _say('해설 그림 찾기 $done/$total'),
      isCancelled: () => _stopped,
    );
    errors.addAll(res.errors);
    await reload();
    return res.withFigures;
  }

  Future<String> _answerSolutionCardUrl(TextbookProblemReviewItem it) async {
    final text = it.answerSolutionCardSource;
    final key = '${it.cropId}|answer_solution|${text.trim().hashCode}';
    final cached = _cardUrls[key];
    if (cached != null) return cached;
    try {
      final url = await service.renderAnswerSolutionCard(
        academyId: scope.academyId,
        item: it,
        solutionText: it.primarySolutionText,
        solutionKind: it.primarySolutionKind,
      );
      if (url.isNotEmpty) _cardUrls[key] = url;
      return url;
    } catch (e) {
      errors.add('${it.problemNumber}번 정답·해설 카드: $e');
      return '';
    }
  }

  /// 정답·해설 카드를 V2 로 찍어 문항 카드·교재 원본과 함께 학생 시점 렌더 검수를 맡긴다.
  Future<int> _renderCheckPass({List<TextbookProblemReviewItem>? only}) async {
    final targets = (only ?? items.where((x) => x.needsRenderCheck)).toList();
    if (targets.isEmpty) return 0;

    Future<Map<String, dynamic>?> payload(TextbookProblemReviewItem it) async {
      final problemUrl = previewUrls[it.cropId] ?? '';
      var solUrl = '';
      if (it.primarySolutionText.isNotEmpty || it.displayAnswer.isNotEmpty) {
        solUrl = await _answerSolutionCardUrl(it);
      }
      if (problemUrl.isEmpty && solUrl.isEmpty) return null;
      final original = problemUrl.isEmpty ? const <String, dynamic>{} : await service.originalImagesJson(scope, it);
      final solutionOriginal = solUrl.isEmpty ? const <String, dynamic>{} : await service.solutionOriginalJson(scope, it);
      return {
        'crop_id': it.cropId,
        if (problemUrl.isNotEmpty) 'problem_url': problemUrl,
        if (solUrl.isNotEmpty) 'answer_solution_url': solUrl,
        'solution_kind': it.primarySolutionKind,
        'is_fill_in_blank': it.isFillInBlank,
        ...original,
        ...solutionOriginal,
      };
    }

    final chunks = <List<TextbookProblemReviewItem>>[
      for (var i = 0; i < targets.length; i += _renderCheckChunkSize) targets.skip(i).take(_renderCheckChunkSize).toList(),
    ];
    var checked = 0;
    var done = 0;
    var next = 0;
    Future<void> worker() async {
      while (next < chunks.length) {
        if (_stopped) return;
        final chunk = chunks[next++];
        try {
          final body = [
            for (final p in await Future.wait(chunk.map(payload)))
              if (p != null) p,
          ];
          if (body.isNotEmpty) {
            final res = await service.runRenderCheck(academyId: scope.academyId, items: body);
            checked += (res['processed'] as num?)?.toInt() ?? 0;
          }
        } catch (e) {
          errors.add('${chunk.map((x) => x.problemNumber).join(',')}번 V2 렌더 검수: $e');
        }
        done += chunk.length;
        _say('V2 렌더 검수 $done/${targets.length}');
      }
    }

    _say('V2 렌더 검수 0/${targets.length}');
    await Future.wait([
      for (var w = 0; w < _renderCheckParallel && w < chunks.length; w++) worker(),
    ]);
    await reload();
    return checked;
  }

  /// 원본 대조 수정 단계(textbook_problem_fix). 반환: 수정안을 만든 문항 수
  Future<int> _fixPass(List<TextbookProblemReviewItem> targets) async {
    var done = 0;
    final chunks = <List<TextbookProblemReviewItem>>[
      for (var i = 0; i < targets.length; i += _fixChunkSize) targets.skip(i).take(_fixChunkSize).toList(),
    ];
    for (var b = 0; b < chunks.length; b += 2) {
      if (_stopped) break;
      final batch = chunks.skip(b).take(2).toList();
      final end = (b * _fixChunkSize + batch.fold<int>(0, (s, c) => s + c.length)).clamp(1, targets.length);
      _say('원본·해설 PDF 대조 수정안 ${b * _fixChunkSize + 1}~$end/${targets.length}');
      final counts = await Future.wait([
        for (final chunk in batch)
          () async {
            try {
              final images = await service.prepareChunkImages(
                scope: scope,
                items: chunk,
                previewUrlsByCropId: previewUrls,
                includeSolution: true,
                includeSolutionPageFallback: true,
                allItems: allItems,
              );
              final ids = <String>[];
              for (final it in chunk) {
                if (images[it.cropId]?.original != null) {
                  ids.add(it.cropId);
                } else {
                  errors.add('${it.problemNumber}번: 본문 PDF 원본을 찍지 못함');
                }
              }
              if (ids.isEmpty) return 0;
              final res = await service.runFixPass(
                scope,
                cropIds: ids,
                images: {for (final id in ids) id: images[id]!},
              );
              return (res['processed'] as num?)?.toInt() ?? 0;
            } catch (e) {
              errors.add('${chunk.map((x) => x.problemNumber).join(',')}번 원본 대조: $e');
              return 0;
            }
          }(),
      ]);
      for (final c in counts) {
        done += c;
      }
    }
    return done;
  }

  /// 지금 본문·교재 원본으로 다시 풀어(math_only) 채점 정답·해설 정답과 대조한다.
  Future<int> _mathResolvePass(List<TextbookProblemReviewItem> targets) async {
    final todo = [for (final it in targets) if (_mathResolvedSig[it.cropId] != it.problemTextSignature) it];
    var done = 0;
    for (var i = 0; i < todo.length; i += _reviewChunkSize) {
      if (_stopped) break;
      final chunk = todo.skip(i).take(_reviewChunkSize).toList();
      _say('수학 재풀이 ${i + 1}~${i + chunk.length}/${todo.length}');
      try {
        final images = await service.prepareChunkImages(
          scope: scope,
          items: chunk,
          previewUrlsByCropId: previewUrls,
          onlyMissingSolutions: true,
        );
        final res = await service.runReviewChunk(
          scope,
          chunkSize: chunk.length,
          mathOnly: true,
          cropIds: [for (final x in chunk) x.cropId],
          images: images,
        );
        done += (res['processed'] as num?)?.toInt() ?? 0;
        for (final x in chunk) {
          _mathResolvedSig[x.cropId] = x.problemTextSignature;
        }
      } catch (e) {
        errors.add('${chunk.map((x) => x.problemNumber).join(',')}번 재풀이: $e');
      }
    }
    return done;
  }

  /// 정답 수정안(합의된 정답·해설 정답)을 채점 정답과 문제은행에 반영한다. 반환: 수학 승인까지 마친 crop id
  Future<List<String>> _bulkMathFixes(List<String> notes) async {
    final approved = <String>{};
    final needProposal = [
      for (final it in items)
        if (it.mathStatus == 'issue' &&
            it.proposedAnswer == null &&
            !it.solutionAndAiAgreeAgainstExisting &&
            !it.existingConfirmedByAi &&
            !it.existingMatchesSolution &&
            it.canRenderOriginal)
          it,
    ];
    if (needProposal.isNotEmpty) {
      final n = await _fixPass(needProposal);
      if (n > 0) notes.add('원본·해설 대조 정답 수정안 $n문항');
      await reload();
    }

    final targets = [
      for (final it in items)
        if (it.mathStatus != 'approved' ||
            it.pbAnswerDiffers ||
            it.hasOpenFindings &&
                it.findings.any((f) => f['axis'] == 'validity' || '${f['check_key']}'.startsWith('load:answer')))
          it,
    ];
    var applied = 0;
    final modified = <String>{};
    for (var i = 0; i < targets.length; i++) {
      if (_stopped) break;
      final it = targets[i];
      final ans = it.resolvedMathAnswer ?? it.existingAnswer.trim();
      if (ans.isEmpty || ans == '판단불가') continue;
      // 운영자가 원본에서 직접 지정한 정답은 AI 제안으로 바꾸지 않는다. 다르면 오류로 남겨 사람이 고른다.
      if (it.answerManual && ans != it.existingAnswer.trim()) continue;
      _say('정답 수정안 반영 ${i + 1}/${targets.length}');
      try {
        await service.saveItemEdit(
          cropId: it.cropId,
          newAnswer: ans,
          aiSolution: it.proposedAiSolution ?? it.aiSolution,
          aiAnswer: it.proposedAiAnswer ?? ans,
          visualTags: it.visualTags,
          solutionTranscribed: it.proposedSolutionTranscribed,
          solutionAnswer: it.proposedSolutionAnswer,
          approveMath: true,
        );
        applied++;
        modified.add(it.cropId);
        approved.add(it.cropId);
      } catch (e) {
        errors.add('${it.problemNumber}번 정답 반영: $e');
      }
    }
    if (applied > 0) notes.add('정답 $applied문항 반영');
    if (_stopped) return approved.toList();
    await reload();

    final still = [for (final it in items) if (it.mathStatus == 'issue' && !modified.contains(it.cropId)) it];
    if (still.isNotEmpty) {
      final resolved = await _mathResolvePass(still);
      if (resolved > 0) {
        notes.add('수학 재풀이 $resolved문항');
        await reload();
        for (final it in items) {
          if (it.mathStatus != 'issue' || it.resolvedMathAnswer == null) continue;
          if (it.answerManual && it.resolvedMathAnswer != it.existingAnswer.trim()) continue;
          try {
            await service.saveItemEdit(
              cropId: it.cropId,
              newAnswer: it.resolvedMathAnswer,
              aiSolution: it.proposedAiSolution ?? it.aiSolution,
              aiAnswer: it.proposedAiAnswer ?? it.resolvedMathAnswer,
              visualTags: it.visualTags,
              approveMath: true,
            );
            approved.add(it.cropId);
          } catch (e) {
            errors.add('${it.problemNumber}번 재풀이 정답 반영: $e');
          }
        }
      }
    }
    return approved.toList();
  }

  /// 공통 발문 중복·문항 유형을 규칙으로 고치고, 원본 대조 수정안(본문·선지·그림)을 반영한 뒤
  /// 바뀐 문항만 V2 로 다시 찍어 원본과 대조한다. 반환: 품질 승인 대상 crop id
  Future<List<String>> _bulkQualityFixes(List<String> notes) async {
    final approvedIds = <String>{};
    final scopedIds = {for (final x in items) x.cropId};

    final falseHeld = [
      for (final x in items)
        if (x.isEngineHeld &&
            (x.issueKind == 'data' ||
                x.hasPendingFixProposal ||
                x.proposalAlreadyReflectedInDb ||
                (x.renderChecks['problem_ok'] == true &&
                    x.renderChecks['fidelity_ok'] != false &&
                    x.renderChecks['issue_kind'] != 'engine')))
          x.cropId,
    ];
    final touched = <String>{};
    if (falseHeld.isNotEmpty) {
      await service.setEngineHold(falseHeld, hold: false);
      touched.addAll(falseHeld);
      await reload();
    }

    final (fixed, approvedByFix, again) = await _applyCommonStemDupFixes();
    if (fixed > 0) notes.add('공통 발문 중복 $fixed문항 수정($approvedByFix문항 승인)');
    touched.addAll(again);
    final kinds = await _applyQuestionKindFixes();
    if (kinds > 0) notes.add('문항 유형 $kinds문항 수정');
    final generated = await _generateObjectiveChoices();
    if (generated > 0) notes.add('주관식 $generated문항 객관식 보기 생성');

    var recheck = <String>{...touched};
    var proposed = 0;
    var applied = 0;
    var heldEngine = 0;
    final checked = <String>{};
    final resized = <String>{};
    for (var round = 0; round < 2; round++) {
      if (_stopped) break;
      await reload();
      final fixTargets = [for (final x in items) if (x.needsFixPass && !x.figureSizeOnlyIssue) x];
      if (fixTargets.isNotEmpty) {
        proposed += await _fixPass(fixTargets);
        await reload();
      }
      if (_stopped) break;

      final done = await _applyPendingProposals(scopedIds);
      applied += done.length;
      recheck.addAll(done);
      touched.addAll(done);

      await reload();
      final pureEngines = [
        for (final x in items)
          if (!x.isEngineHeld &&
              x.qualityStatus == 'issue' &&
              (x.aiSuspectsEngine || '${x.fixProposal['kind'] ?? ''}' == 'engine') &&
              !_textProposalUsable(x) &&
              !x.hasPendingFigureProposal &&
              !x.hasFigures)
            x.cropId,
      ];
      if (pureEngines.isNotEmpty) {
        heldEngine += await service.setEngineHold(pureEngines, hold: true);
        await reload();
      }

      final changed = [
        for (final x in items)
          if (recheck.contains(x.cropId) && !x.isEngineHeld && x.canRenderOriginal) x,
      ];
      if (changed.isNotEmpty && !_stopped) {
        await loadPreviews(changed);
        await _renderCheckPass(only: changed);
        checked.addAll([for (final x in changed) x.cropId]);
      }
      recheck = {};
      if (_stopped) break;

      final sized = await _resizeFigures(scopedIds);
      if (sized.isNotEmpty) {
        resized.addAll(sized);
        touched.addAll(sized);
        await reload();
        final sizedItems = [for (final x in items) if (sized.contains(x.cropId)) x];
        await loadPreviews(sizedItems);
        await _renderCheckPass(only: sizedItems);
      }
      await reload();

      final postEngines = [
        for (final x in items)
          if (!x.isEngineHeld && x.qualityStatus == 'issue' && x.aiSuspectsEngine && !x.hasFigures) x.cropId,
      ];
      if (postEngines.isNotEmpty) {
        heldEngine += await service.setEngineHold(postEngines, hold: true);
        await reload();
      }
      if (!items.any((x) => x.needsFixPass && !x.figureSizeOnlyIssue)) break;
    }

    for (final x in items) {
      if (x.isEngineHeld) continue;
      if (x.qualityStatus == 'clean') {
        approvedIds.add(x.cropId);
      } else if (x.qualityStatus == 'issue' &&
          !checked.contains(x.cropId) &&
          !resized.contains(x.cropId) &&
          x.issueKind != 'figure' &&
          (x.fixProposal['text_matches_original'] == true || x.proposalAlreadyReflectedInDb)) {
        approvedIds.add(x.cropId);
      }
    }

    var healedMath = 0;
    for (final x in items) {
      if (x.mathStatus != 'issue' || x.resolvedMathAnswer == null) continue;
      try {
        await service.saveItemEdit(
          cropId: x.cropId,
          newAnswer: x.resolvedMathAnswer,
          aiSolution: x.proposedAiSolution ?? x.aiSolution,
          aiAnswer: x.proposedAiAnswer ?? x.resolvedMathAnswer,
          visualTags: x.visualTags,
          solutionTranscribed: x.proposedSolutionTranscribed,
          solutionAnswer: x.proposedSolutionAnswer,
          approveMath: true,
        );
        healedMath++;
      } catch (e) {
        errors.add('${x.problemNumber}번 정답 반영: $e');
      }
    }

    if (proposed > 0) notes.add('원본 대조 수정안 $proposed문항');
    if (applied > 0) notes.add('수정안 $applied문항 반영');
    if (checked.isNotEmpty) notes.add('바뀐 문항 재검수 ${checked.length}문항');
    if (resized.isNotEmpty) notes.add('그림 크기 조정 ${resized.length}문항');
    if (heldEngine > 0) notes.add('렌더 엔진 보류 $heldEngine문항');
    if (healedMath > 0) notes.add('복합 오류 정답 $healedMath문항');
    return approvedIds.toList();
  }

  static bool _textProposalUsable(TextbookProblemReviewItem it) =>
      it.hasPendingFixProposal && !it.fixProposalIsCommonStemDup && !it.commonStemDuplicated;

  static bool _onlyIssueIsCommonStemDup(TextbookProblemReviewItem it) {
    final qc = it.qualityChecks;
    final rc = it.renderChecks;
    return qc['choices_ok'] != false &&
        qc['figure_ok'] != false &&
        qc['latex_v2_ok'] != false &&
        qc['fidelity_ok'] != false &&
        rc['answer_ok'] != false &&
        rc['solution_ok'] != false &&
        rc['fidelity_ok'] != false &&
        !it.hasFigures &&
        (!it.hasPendingFixProposal || it.fixProposalIsCommonStemDup);
  }

  List<TextbookProblemReviewItem> get _commonStemDups => [
        for (final it in items)
          if (it.commonStemDuplicated && !it.isEngineHeld && (it.qualityStatus != 'approved' || !it.stage2Superseded)) it,
      ];

  List<TextbookProblemReviewItem> get _pendingProposals => [
        for (final it in items)
          if (!it.isEngineHeld &&
              (it.qualityStatus != 'approved' || !it.stage2Superseded) &&
              (_textProposalUsable(it) ||
                  it.hasPendingFigureProposal ||
                  (it.hasFigures && it.fixAppliedAt == null && (it.proposedFigureLayout != null || it.pbFigureLayout.isNotEmpty))))
            it,
      ];

  /// 반환: (수정 문항 수, 그중 승인 수, 렌더 재검수할 crop id)
  Future<(int, int, List<String>)> _applyCommonStemDupFixes() async {
    var fixed = 0;
    var approved = 0;
    final recheck = <String>[];
    final touched = <String>{};
    var pending = _commonStemDups;
    for (var round = 0; round < 4 && pending.isNotEmpty; round++) {
      var progressed = false;
      for (final it in pending) {
        final fix = it.commonStemFix;
        if (fix == null) continue;
        final approve = _onlyIssueIsCommonStemDup(it);
        touched.add(it.cropId);
        try {
          await service.applyProblemFix(
            cropId: it.cropId,
            stem: fix.stem,
            commonStem: fix.commonStem,
            approveQuality: approve,
            note: '공통 발문 중복 제거(일괄)',
          );
        } catch (e) {
          errors.add('${it.problemNumber}번: $e');
          continue;
        }
        progressed = true;
        fixed++;
        if (approve) {
          approved++;
        } else {
          recheck.add(it.cropId);
        }
      }
      if (!progressed) break;
      await reload();
      pending = [for (final x in _commonStemDups) if (!touched.contains(x.cropId)) x];
    }
    if (touched.isNotEmpty) {
      await loadPreviews([for (final x in items) if (touched.contains(x.cropId)) x]);
    }
    return (fixed, approved, recheck);
  }

  Future<int> _applyQuestionKindFixes() async {
    var n = 0;
    for (final it in [for (final x in items) if (x.questionKindMismatch) x]) {
      try {
        final kind = it.expectedQuestionKind;
        if (await service.setQuestionKind(it.cropId, kind,
            allowSubjective: kind == 'objective' && it.answerChoiceCount > 0 ? it.subjectiveAlsoPossible : null)) {
          n++;
        }
      } catch (e) {
        errors.add('${it.problemNumber}번 유형: $e');
      }
    }
    if (n > 0) await reload();
    return n;
  }

  Future<int> _generateObjectiveChoices() async {
    if (!service.hasGateway) return 0;
    var n = 0;
    for (final it in [for (final x in items) if (x.needsObjectiveGeneration) x]) {
      if (_stopped) break;
      _say('${it.problemNumber}번 객관식 보기 생성');
      try {
        if (await service.generateObjectiveChoices(it)) n++;
      } catch (e) {
        errors.add('${it.problemNumber}번 객관식 보기: $e');
      }
    }
    if (n > 0) await reload();
    return n;
  }

  Future<Map<String, dynamic>> _applyFixFor(
    TextbookProblemReviewItem item, {
    String? stem,
    List<Map<String, dynamic>>? choices,
    String? commonStem,
    Map<String, dynamic>? figureLayout,
    List<Map<String, dynamic>> figureCrops = const [],
    String? note,
  }) async {
    List<Map<String, dynamic>>? assets;
    if (figureCrops.isNotEmpty) {
      final added = await service.cropAndUploadFigures(scope: scope, item: item, crops: figureCrops);
      if (added.isNotEmpty) assets = [...item.pbFigureAssets, ...added];
    }
    return service.applyProblemFix(
      cropId: item.cropId,
      stem: stem,
      choices: choices,
      commonStem: commonStem,
      figureLayout: figureLayout,
      figureAssets: assets,
      note: note,
    );
  }

  /// 수정안(본문·선지·공통 발문·그림 배치·원본 크롭 그림)을 그대로 적용한다(승인은 하지 않음). 반환: 적용한 crop id
  Future<List<String>> _applyPendingProposals(Set<String> onlyCropIds) async {
    final out = <String>[];
    final targets = [for (final it in _pendingProposals) if (onlyCropIds.contains(it.cropId)) it];
    for (var i = 0; i < targets.length; i++) {
      if (_stopped) break;
      final it = targets[i];
      final text = _textProposalUsable(it);
      final figure = it.hasPendingFigureProposal || (it.hasFigures && it.fixAppliedAt == null);
      _say('수정안 반영 ${i + 1}/${targets.length}');
      try {
        final res = await _applyFixFor(
          it,
          stem: text ? it.proposedStem : null,
          choices: text ? it.proposedChoices : null,
          commonStem: text ? it.proposedCommonStem : null,
          figureLayout: figure ? (it.proposedFigureLayout ?? (it.pbFigureLayout.isNotEmpty ? it.pbFigureLayout : null)) : null,
          figureCrops: figure ? it.proposedFigureCrops : const [],
          note: '원본 대조 수정안 일괄 적용',
        );
        if (((res['changed'] as List?) ?? const []).isNotEmpty || it.hasFigures || it.proposalAlreadyReflectedInDb) {
          out.add(it.cropId);
        }
      } catch (e) {
        errors.add('${it.problemNumber}번 수정안: $e');
      }
    }
    return out;
  }

  /// 원본 대조에서 V2 그림 크기가 원본 비율을 벗어난 문항의 그림 폭을 1/비율 배로 고친다. 반환: 적용한 crop id
  Future<List<String>> _resizeFigures(Set<String> onlyCropIds) async {
    final out = <String>[];
    for (final it in items) {
      if (_stopped) break;
      if (!onlyCropIds.contains(it.cropId)) continue;
      if (it.isEngineHeld || !it.figureNeedsResize) continue;
      final scaled = scaleFigureLayout(
        it.pbFigureLayout,
        1 / it.figureSizeRatio!,
        fallbackAssets: it.pbFigureAssets,
        fallbackCount: figureMarkerCount(it.stem),
      );
      if (figureLayoutItems(scaled).isEmpty) continue;
      try {
        final res = await service.applyProblemFix(
          cropId: it.cropId,
          figureLayout: scaled,
          approveQuality: it.qualityStatus == 'approved',
          note: '그림 크기를 원본 글자 비율에 맞춰 재조정',
        );
        if (((res['changed'] as List?) ?? const []).isNotEmpty) out.add(it.cropId);
      } catch (e) {
        errors.add('${it.problemNumber}번 그림 크기: $e');
      }
    }
    return out;
  }
}
