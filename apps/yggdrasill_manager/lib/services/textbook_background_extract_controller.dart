import 'dart:async';

import 'package:flutter/foundation.dart';

import 'problem_bank_service.dart';

class TextbookBackgroundExtractTask {
  const TextbookBackgroundExtractTask({
    required this.academyId,
    required this.bookId,
    required this.bookName,
    required this.gradeLabel,
    this.linkId,
  });

  final String academyId;
  final String bookId;
  final String bookName;
  final String gradeLabel;
  final int? linkId;

  String get key => '$academyId|$bookId|$gradeLabel';
}

class TextbookBackgroundExtractProgress {
  const TextbookBackgroundExtractProgress({
    this.total = 0,
    this.completed = 0,
    this.queued = 0,
    this.extracting = 0,
    this.failed = 0,
    this.questionCount = 0,
    this.loading = false,
    this.error = '',
  });

  final int total;
  final int completed;
  final int queued;
  final int extracting;
  final int failed;
  final int questionCount;
  final bool loading;
  final String error;

  bool get finished => total > 0 && completed + failed >= total;
}

class TextbookBackgroundExtractEntry {
  const TextbookBackgroundExtractEntry({
    required this.task,
    required this.progress,
  });

  final TextbookBackgroundExtractTask task;
  final TextbookBackgroundExtractProgress progress;
}

/// 단원 분석 다이얼로그를 닫아도 서버 문제은행 추출 상태를 계속 추적한다.
///
/// 실제 장시간 작업은 `pb_extract_jobs` 워커에서 실행되므로 클라이언트는
/// 작업을 소유하지 않고 `textbook_pb_extract_runs` 상태만 주기적으로 읽는다.
class TextbookBackgroundExtractController extends ChangeNotifier {
  TextbookBackgroundExtractController._();

  static final TextbookBackgroundExtractController instance =
      TextbookBackgroundExtractController._();

  final ProblemBankService _service = ProblemBankService();
  final Map<String, TextbookBackgroundExtractEntry> _entries =
      <String, TextbookBackgroundExtractEntry>{};
  Timer? _pollTimer;
  bool _refreshing = false;

  List<TextbookBackgroundExtractEntry> get entries =>
      _entries.values.toList(growable: false);

  void minimize(TextbookBackgroundExtractTask task) {
    _entries[task.key] = TextbookBackgroundExtractEntry(
      task: task,
      progress: const TextbookBackgroundExtractProgress(loading: true),
    );
    notifyListeners();
    _ensurePolling();
    unawaited(refresh());
  }

  void remove(String key) {
    if (_entries.remove(key) == null) return;
    if (_entries.isEmpty) {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
    notifyListeners();
  }

  Future<void> refresh() async {
    if (_refreshing || _entries.isEmpty) return;
    _refreshing = true;
    try {
      for (final entry in List<TextbookBackgroundExtractEntry>.from(
        _entries.values,
      )) {
        await _refreshOne(entry.task);
      }
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _refreshOne(TextbookBackgroundExtractTask task) async {
    try {
      final rows = await _service.listTextbookPdfExtractRuns(
        academyId: task.academyId,
        bookId: task.bookId,
        gradeLabel: task.gradeLabel,
      );
      var completed = 0;
      var queued = 0;
      var extracting = 0;
      var failed = 0;
      var questionCount = 0;
      for (final row in rows) {
        final status = '${row['status'] ?? ''}'.trim().toLowerCase();
        switch (status) {
          case 'completed':
          case 'review_required':
            completed += 1;
          case 'queued':
            queued += 1;
          case 'extracting':
            extracting += 1;
          case 'failed':
          case 'cancelled':
            failed += 1;
        }
        final summary = row['result_summary'];
        if (summary is Map) {
          questionCount +=
              _asInt(summary['totalQuestions'] ?? summary['total_questions']);
        }
      }
      _entries[task.key] = TextbookBackgroundExtractEntry(
        task: task,
        progress: TextbookBackgroundExtractProgress(
          total: rows.length,
          completed: completed,
          queued: queued,
          extracting: extracting,
          failed: failed,
          questionCount: questionCount,
        ),
      );
    } catch (e) {
      _entries[task.key] = TextbookBackgroundExtractEntry(
        task: task,
        progress: TextbookBackgroundExtractProgress(error: '$e'),
      );
    }
    notifyListeners();
  }

  void _ensurePolling() {
    _pollTimer ??= Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(refresh()),
    );
  }

  static int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? 0;
  }
}
