import 'dart:async';

import 'package:flutter/foundation.dart';

import 'textbook_pdf_service.dart';

enum TextbookDownloadPhase {
  downloading,
  completed,
  failed,
}

class TextbookDownloadJob {
  const TextbookDownloadJob({
    required this.id,
    required this.title,
    required this.ref,
    required this.phase,
    this.received = 0,
    this.total = 0,
    this.error,
    this.minimized = false,
    this.onCompleted,
  });

  final String id;
  final String title;
  final TextbookPdfRef ref;
  final TextbookDownloadPhase phase;
  final int received;
  final int total;
  final String? error;
  final bool minimized;
  final VoidCallback? onCompleted;

  double? get progress {
    if (total <= 0) return null;
    return (received / total).clamp(0.0, 1.0);
  }

  TextbookDownloadJob copyWith({
    TextbookDownloadPhase? phase,
    int? received,
    int? total,
    String? error,
    bool? minimized,
    bool clearError = false,
  }) {
    return TextbookDownloadJob(
      id: id,
      title: title,
      ref: ref,
      phase: phase ?? this.phase,
      received: received ?? this.received,
      total: total ?? this.total,
      error: clearError ? null : (error ?? this.error),
      minimized: minimized ?? this.minimized,
      onCompleted: onCompleted,
    );
  }
}

/// 마이그레이션 교재 PDF 백그라운드 다운로드 상태.
/// 전체 화면 뷰어 대신 우하단 안내창으로 진행 상황을 보여 준다.
class TextbookDownloadProgressService {
  TextbookDownloadProgressService._();
  static final TextbookDownloadProgressService instance =
      TextbookDownloadProgressService._();

  final ValueNotifier<List<TextbookDownloadJob>> jobsNotifier =
      ValueNotifier<List<TextbookDownloadJob>>(const <TextbookDownloadJob>[]);

  final Set<String> _running = <String>{};
  final Map<String, VoidCallback?> _onCompletedById = <String, VoidCallback?>{};

  static String jobIdFor(TextbookPdfRef ref) {
    final academy = (ref.academyId ?? '').trim();
    final file = (ref.fileId ?? '').trim();
    final grade = (ref.gradeLabel ?? '').trim();
    final kind = (ref.kind ?? 'body').trim();
    if (academy.isNotEmpty && file.isNotEmpty) {
      return '$academy|$file|$grade|$kind';
    }
    if (ref.linkId != null) return 'link:${ref.linkId}';
    final storage = (ref.storageKey ?? '').trim();
    if (storage.isNotEmpty) return 'storage:$storage';
    return 'anon:${ref.displayName ?? 'textbook'}';
  }

  TextbookDownloadJob? jobById(String id) {
    for (final job in jobsNotifier.value) {
      if (job.id == id) return job;
    }
    return null;
  }

  /// 이미 진행 중이면 안내창만 다시 펼치고, 아니면 다운로드를 시작한다.
  Future<void> enqueue({
    required TextbookPdfRef ref,
    required String title,
    VoidCallback? onCompleted,
  }) async {
    final id = jobIdFor(ref);
    final displayTitle = title.trim().isEmpty ? '교재' : title.trim();
    if (onCompleted != null) {
      _onCompletedById[id] = onCompleted;
    }
    final existing = jobById(id);
    if (existing != null) {
      if (existing.phase == TextbookDownloadPhase.downloading) {
        _replace(
          TextbookDownloadJob(
            id: existing.id,
            title: displayTitle,
            ref: existing.ref,
            phase: existing.phase,
            received: existing.received,
            total: existing.total,
            minimized: false,
            onCompleted: _onCompletedById[id],
          ),
        );
        return;
      }
      if (existing.phase == TextbookDownloadPhase.completed) {
        _fireCompleted(id);
        return;
      }
      // failed → retry below
      _remove(id);
    }

    // 안내창만 닫혀 있고 다운로드는 아직 돌아가는 경우 — UI만 다시 붙인다.
    if (_running.contains(id)) {
      _upsert(
        TextbookDownloadJob(
          id: id,
          title: displayTitle,
          ref: ref,
          phase: TextbookDownloadPhase.downloading,
          onCompleted: _onCompletedById[id],
        ),
      );
      return;
    }

    final job = TextbookDownloadJob(
      id: id,
      title: displayTitle,
      ref: ref,
      phase: TextbookDownloadPhase.downloading,
      onCompleted: _onCompletedById[id],
    );
    _upsert(job);
    _running.add(id);
    unawaited(_run(job));
  }

  void setMinimized(String id, bool minimized) {
    final job = jobById(id);
    if (job == null) return;
    _replace(job.copyWith(minimized: minimized));
  }

  void dismiss(String id) {
    _remove(id);
  }

  Future<void> _run(TextbookDownloadJob seed) async {
    final id = seed.id;
    try {
      await TextbookPdfService.instance.resolve(
        seed.ref,
        onProgress: (received, total) {
          final current = jobById(id);
          if (current == null) return;
          _replace(
            current.copyWith(
              phase: TextbookDownloadPhase.downloading,
              received: received,
              total: total,
              clearError: true,
            ),
          );
        },
      );
      final current = jobById(id);
      if (current != null) {
        _replace(
          current.copyWith(
            phase: TextbookDownloadPhase.completed,
            clearError: true,
          ),
        );
      }
      _fireCompleted(id);
      // 완료 배너를 잠시 보여 준 뒤 자동으로 접는다.
      await Future<void>.delayed(const Duration(seconds: 4));
      final latest = jobById(id);
      if (latest != null && latest.phase == TextbookDownloadPhase.completed) {
        _remove(id);
      }
    } catch (e) {
      final current = jobById(id);
      if (current == null) {
        // 안내창이 닫힌 채 실패해도 재시도할 수 있게 실패 카드를 다시 띄운다.
        _upsert(
          TextbookDownloadJob(
            id: id,
            title: seed.title,
            ref: seed.ref,
            phase: TextbookDownloadPhase.failed,
            error: '$e',
            onCompleted: _onCompletedById[id],
          ),
        );
      } else {
        _replace(
          current.copyWith(
            phase: TextbookDownloadPhase.failed,
            error: '$e',
            minimized: false,
          ),
        );
      }
    } finally {
      _running.remove(id);
    }
  }

  void _fireCompleted(String id) {
    final callback = _onCompletedById.remove(id);
    try {
      callback?.call();
    } catch (_) {}
  }

  void _upsert(TextbookDownloadJob job) {
    final next = List<TextbookDownloadJob>.from(jobsNotifier.value);
    final index = next.indexWhere((item) => item.id == job.id);
    if (index >= 0) {
      next[index] = job;
    } else {
      next.add(job);
    }
    jobsNotifier.value = next;
  }

  void _replace(TextbookDownloadJob job) => _upsert(job);

  void _remove(String id) {
    final next =
        jobsNotifier.value.where((job) => job.id != id).toList(growable: false);
    if (next.length == jobsNotifier.value.length) return;
    jobsNotifier.value = next;
  }
}
