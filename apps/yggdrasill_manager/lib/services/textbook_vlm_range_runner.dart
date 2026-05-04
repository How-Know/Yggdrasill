// Shared page-range VLM runner.
//
// Extracted from `textbook_vlm_test_dialog` so the unit-authoring dialog can
// reuse the same analyze + auto-retry logic without duplicating the state
// machine. This file owns:
//   1. transient-error classification (`_isRetriableError`)
//   2. single-page analysis with exponential-ish backoff
//   3. an async iterator that walks a [start, end] range and collects
//      per-page success/failure without forcing a specific UI shape
//
// Everything is framework-agnostic on purpose — callers pass their own PDF
// document handle, a renderer function, and a VLM client. That way the
// existing test dialog and the new authoring dialog can thread their own
// state management (setState, ChangeNotifier, whatever) around the runner.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'textbook_vlm_test_service.dart';

typedef PageRenderFn = Future<Uint8List> Function({
  required int rawPage,
  required int longEdgePx,
});

typedef VlmDetectFn = Future<TextbookVlmDetectResult> Function({
  required Uint8List imageBytes,
  required int rawPage,
});

class PageAnalysisOutcome {
  const PageAnalysisOutcome({
    required this.rawPage,
    required this.result,
    required this.renderedPng,
    required this.attempts,
  });

  final int rawPage;
  final TextbookVlmDetectResult result;
  final Uint8List renderedPng;
  final int attempts;
}

class PageAnalysisFailure {
  const PageAnalysisFailure({
    required this.rawPage,
    required this.error,
    required this.attempts,
  });

  final int rawPage;
  final Object error;
  final int attempts;
}

class RangeProgress {
  const RangeProgress({
    required this.cursor,
    required this.total,
    required this.done,
    required this.failed,
    required this.failedPages,
    this.lastError,
  });

  final int cursor;
  final int total;
  final int done;
  final int failed;
  final Set<int> failedPages;
  final String? lastError;

  RangeProgress copyWith({
    int? cursor,
    int? total,
    int? done,
    int? failed,
    Set<int>? failedPages,
    String? lastError,
  }) {
    return RangeProgress(
      cursor: cursor ?? this.cursor,
      total: total ?? this.total,
      done: done ?? this.done,
      failed: failed ?? this.failed,
      failedPages: failedPages ?? this.failedPages,
      lastError: lastError ?? this.lastError,
    );
  }
}

/// Classify transient errors (mostly keep-alive races between the Dart HTTP
/// client and the Node gateway) so the runner can retry them quietly.
bool isRetriableVlmError(Object err) {
  final s = '$err'.toLowerCase();
  return s.contains('connection closed before full header') ||
      s.contains('connection reset') ||
      s.contains('softwarecausedconnectionabort') ||
      s.contains('httpexception') ||
      s.contains('socketexception') ||
      s.contains('os error: connection') ||
      s.contains('timeoutexception') ||
      s.contains('missing bbox') ||
      s.contains('missing item_region');
}

/// Render + detect a single page with retries. [isCancelled] is consulted
/// between attempts so long unit analyses can be interrupted cleanly.
Future<PageAnalysisOutcome> analyzeSinglePageWithRetry({
  required int rawPage,
  required int analysisLongEdgePx,
  required PageRenderFn renderer,
  required VlmDetectFn detector,
  int retries = 1,
  bool Function()? isCancelled,
  void Function(int attempt, Object error)? onRetry,
}) async {
  var attempt = 0;
  while (true) {
    attempt += 1;
    try {
      final png = await renderer(
        rawPage: rawPage,
        longEdgePx: analysisLongEdgePx,
      );
      final result = await detector(imageBytes: png, rawPage: rawPage);
      final hasItems = result.items.isNotEmpty;
      final isProblemSection =
          result.section == 'type_practice' || result.section == 'mastery';
      if (result.pageKind != 'concept_page' && isProblemSection && !hasItems) {
        throw StateError(
          'missing VLM items on ${result.section} page $rawPage',
        );
      }
      final missingRegionCount = result.items
          .where((item) => (item.itemRegion?.length ?? 0) != 4)
          .length;
      if (result.pageKind != 'concept_page' &&
          hasItems &&
          missingRegionCount > 0) {
        throw StateError(
          'missing item_region for $missingRegionCount/${result.items.length} VLM items '
          'on page $rawPage',
        );
      }
      final missingBboxCount =
          result.items.where((item) => (item.bbox?.length ?? 0) != 4).length;
      if (result.pageKind != 'concept_page' &&
          hasItems &&
          missingBboxCount > 0) {
        throw StateError(
          'missing bbox for $missingBboxCount/${result.items.length} VLM items '
          'on page $rawPage',
        );
      }
      return PageAnalysisOutcome(
        rawPage: rawPage,
        result: result,
        renderedPng: png,
        attempts: attempt,
      );
    } catch (err) {
      if (attempt > retries || !isRetriableVlmError(err)) rethrow;
      if (isCancelled?.call() == true) rethrow;
      onRetry?.call(attempt, err);
      final waitMs = 500 * attempt;
      if (kDebugMode) {
        debugPrint('[vlm-range] retriable error on page $rawPage '
            '(attempt $attempt, wait ${waitMs}ms): $err');
      }
      await Future<void>.delayed(Duration(milliseconds: waitMs));
    }
  }
}

/// Walks `[start, end]` sequentially. Emits per-page results/failures via
/// [onPageDone] and coarse-grained progress snapshots via [onProgress] so
/// callers can drive a progress bar without managing counters themselves.
///
/// Returns the final [RangeProgress] once the loop finishes (or is cancelled).
Future<RangeProgress> runRangeAnalysis({
  required int startPage,
  required int endPage,
  required int analysisLongEdgePx,
  required PageRenderFn renderer,
  required VlmDetectFn detector,
  int retriesPerPage = 1,
  bool Function()? isCancelled,
  void Function(PageAnalysisOutcome outcome)? onPageSuccess,
  void Function(PageAnalysisFailure failure)? onPageFailure,
  void Function(RangeProgress progress)? onProgress,
}) async {
  if (endPage < startPage) {
    return RangeProgress(
      cursor: startPage,
      total: 0,
      done: 0,
      failed: 0,
      failedPages: <int>{},
    );
  }
  final failedPages = <int>{};
  var done = 0;
  var failed = 0;
  String? lastError;
  final total = endPage - startPage + 1;

  void emit(int cursor) {
    onProgress?.call(RangeProgress(
      cursor: cursor,
      total: total,
      done: done,
      failed: failed,
      failedPages: Set<int>.from(failedPages),
      lastError: lastError,
    ));
  }

  for (var p = startPage; p <= endPage; p += 1) {
    if (isCancelled?.call() == true) break;
    emit(p);
    try {
      final outcome = await analyzeSinglePageWithRetry(
        rawPage: p,
        analysisLongEdgePx: analysisLongEdgePx,
        renderer: renderer,
        detector: detector,
        retries: retriesPerPage,
        isCancelled: isCancelled,
      );
      done += 1;
      onPageSuccess?.call(outcome);
    } catch (err) {
      failed += 1;
      failedPages.add(p);
      lastError = '페이지 $p: $err';
      onPageFailure?.call(PageAnalysisFailure(
        rawPage: p,
        error: err,
        attempts: retriesPerPage + 1,
      ));
    }
    emit(p);
  }

  return RangeProgress(
    cursor: endPage,
    total: total,
    done: done,
    failed: failed,
    failedPages: failedPages,
    lastError: lastError,
  );
}

/// Retry only the specified [pages] with a slightly more patient policy.
/// Follows the same contract as [runRangeAnalysis] so callers can plug it
/// into the same "실패 재분석" button.
Future<RangeProgress> retryFailedPages({
  required List<int> pages,
  required int analysisLongEdgePx,
  required PageRenderFn renderer,
  required VlmDetectFn detector,
  int retriesPerPage = 2,
  bool Function()? isCancelled,
  void Function(PageAnalysisOutcome outcome)? onPageSuccess,
  void Function(PageAnalysisFailure failure)? onPageFailure,
  void Function(RangeProgress progress)? onProgress,
}) async {
  if (pages.isEmpty) {
    return RangeProgress(
      cursor: 0,
      total: 0,
      done: 0,
      failed: 0,
      failedPages: <int>{},
    );
  }
  final failedPages = <int>{...pages};
  var done = 0;
  var failed = 0;
  String? lastError;
  final total = pages.length;

  void emit(int cursor) {
    onProgress?.call(RangeProgress(
      cursor: cursor,
      total: total,
      done: done,
      failed: failed,
      failedPages: Set<int>.from(failedPages),
      lastError: lastError,
    ));
  }

  for (final p in pages) {
    if (isCancelled?.call() == true) break;
    emit(p);
    try {
      final outcome = await analyzeSinglePageWithRetry(
        rawPage: p,
        analysisLongEdgePx: analysisLongEdgePx,
        renderer: renderer,
        detector: detector,
        retries: retriesPerPage,
        isCancelled: isCancelled,
      );
      done += 1;
      failedPages.remove(p);
      onPageSuccess?.call(outcome);
    } catch (err) {
      failed += 1;
      lastError = '페이지 $p: $err';
      onPageFailure?.call(PageAnalysisFailure(
        rawPage: p,
        error: err,
        attempts: retriesPerPage + 1,
      ));
    }
    emit(p);
  }

  return RangeProgress(
    cursor: pages.last,
    total: total,
    done: done,
    failed: failed,
    failedPages: failedPages,
    lastError: lastError,
  );
}
