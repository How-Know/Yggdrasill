import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/problem_bank_service.dart';
import '../../widgets/latex_text_renderer.dart';
import 'problem_bank_models.dart';

class ProblemBankScreen extends StatefulWidget {
  const ProblemBankScreen({super.key});

  @override
  State<ProblemBankScreen> createState() => _ProblemBankScreenState();
}

class _ProblemBankScreenState extends State<ProblemBankScreen> {
  static const Color _bg = Color(0xFF0B1112);
  static const Color _panel = Color(0xFF10171A);
  static const Color _field = Color(0xFF15171C);
  static const Color _border = Color(0xFF223131);
  static const Color _text = Color(0xFFEAF2F2);
  static const Color _textSub = Color(0xFF9FB3B3);
  static const Color _accent = Color(0xFF33A373);
  static const double _previewMathScale = 1.10;
  // 분수는 명령(\dfrac) 승격으로 키우고, 식 전체 스케일은 일반 수식과 동일하게 유지한다.
  static const double _previewFractionMathScale = _previewMathScale;

  static const List<String> _templateOptions = <String>[
    '내신형',
    '수능형',
    '모의고사형',
  ];
  static const List<String> _paperOptions = <String>['A4', 'B4', '8절'];

  final ProblemBankService _service = ProblemBankService();

  Timer? _pollTimer;
  bool _bootstrapLoading = true;
  bool _isUploading = false;
  bool _isExtracting = false;
  bool _isExporting = false;
  bool _isResetting = false;
  bool _hasExtracted = false;
  bool _hasExported = false;
  bool _showLowConfidenceOnly = false;
  bool _schemaMissing = false;
  bool _academyMissing = false;
  String _statusText = '초기화 중...';

  String? _academyId;
  String _selectedTemplate = _templateOptions.first;
  String _selectedPaper = _paperOptions.first;
  bool _includeAnswerSheet = true;
  bool _includeExplanation = false;

  List<ProblemBankDocument> _documents = <ProblemBankDocument>[];
  ProblemBankDocument? _activeDocument;
  ProblemBankExtractJob? _activeExtractJob;
  ProblemBankExportJob? _activeExportJob;
  List<ProblemBankQuestion> _questions = <ProblemBankQuestion>[];
  final List<_PipelineLogEntry> _pipelineLogs = <_PipelineLogEntry>[];
  final Map<String, String> _figurePreviewUrls = <String, String>{};
  final Map<String, String> _figurePreviewPaths = <String, String>{};
  final Map<String, Map<String, String>> _figurePreviewUrlsByPath =
      <String, Map<String, String>>{};
  final Set<String> _figureGenerating = <String>{};
  final Map<String, String> _scoreDrafts = <String, String>{};
  final Set<String> _scoreSaving = <String>{};
  bool _isFigurePolling = false;
  String? _lastExtractStatus;
  String? _lastExportStatus;
  bool _queuedLongWaitWarned = false;

  int get _checkedCount => _questions.where((q) => q.isChecked).length;
  int get _lowConfidenceCount => _questions.where(_isLowConfidence).length;
  List<ProblemBankQuestion> get _visibleQuestions => _showLowConfidenceOnly
      ? _questions.where(_isLowConfidence).toList(growable: false)
      : _questions;

  Duration? get _extractQueuedElapsed {
    final job = _activeExtractJob;
    if (job == null || job.status != 'queued') {
      return null;
    }
    final elapsed = DateTime.now().difference(job.createdAt);
    if (elapsed.isNegative) return Duration.zero;
    return elapsed;
  }

  bool get _progressIndeterminate {
    final extractStatus = _activeExtractJob?.status ?? '';
    final exportStatus = _activeExportJob?.status ?? '';
    return _isResetting ||
        extractStatus == 'queued' ||
        extractStatus == 'extracting' ||
        exportStatus == 'queued' ||
        exportStatus == 'rendering' ||
        _isFigurePolling ||
        _figureGenerating.isNotEmpty;
  }

  double get _progressValue {
    if (_isResetting) return 0.04;
    if (_isUploading) return 0.08;
    final extractStatus = _activeExtractJob?.status ?? '';
    final exportStatus = _activeExportJob?.status ?? '';
    if (extractStatus == 'queued') return 0.18;
    if (extractStatus == 'extracting') return 0.46;
    if (extractStatus == 'review_required' || extractStatus == 'completed') {
      if (exportStatus == 'queued') return 0.82;
      if (exportStatus == 'rendering') return 0.92;
      if (exportStatus == 'completed') return 1.0;
      if (_isFigurePolling || _figureGenerating.isNotEmpty) return 0.74;
      return _checkedCount > 0 ? 0.78 : 0.72;
    }
    if (_hasExported) return 1.0;
    if (_hasExtracted) return _checkedCount > 0 ? 0.78 : 0.72;
    return 0.0;
  }

  String get _progressLabel {
    final extractStatus = _activeExtractJob?.status ?? '';
    final exportStatus = _activeExportJob?.status ?? '';
    if (_isResetting) return '이전 작업 초기화 중...';
    if (_isUploading) return '업로드 중 (1/4)';
    if (extractStatus == 'queued') {
      final elapsed = _extractQueuedElapsed;
      if (elapsed == null) return '추출 대기열 등록됨 (2/4)';
      return '추출 대기열 대기 중 (2/4, ${_formatElapsed(elapsed)})';
    }
    if (extractStatus == 'extracting') return '한글/수식 추출 중 (2/4)';
    if (extractStatus == 'review_required' || extractStatus == 'completed') {
      if (_isFigurePolling || _figureGenerating.isNotEmpty) {
        return 'AI 그림 생성 중 (3/4)';
      }
      if (_checkedCount == 0) return '검수 대기 중 (3/4)';
      if (exportStatus == 'queued') return 'PDF 생성 대기 중 (4/4)';
      if (exportStatus == 'rendering') return 'PDF 생성 중 (4/4)';
      if (exportStatus == 'completed') return '완료 (4/4)';
      return '검수 진행 중 (3/4)';
    }
    return '대기 중';
  }

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  String _templateToProfile(String template) {
    switch (template) {
      case '수능형':
        return 'csat';
      case '모의고사형':
        return 'mock';
      case '내신형':
      default:
        return 'naesin';
    }
  }

  void _showSnack(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? const Color(0xFFDE6A73) : _accent,
      ),
    );
  }

  String _formatElapsed(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }

  void _appendPipelineLog(
    String stage,
    String message, {
    bool error = false,
  }) {
    if (!mounted) return;
    setState(() {
      _pipelineLogs.insert(
        0,
        _PipelineLogEntry(
          at: DateTime.now(),
          stage: stage,
          message: message,
          isError: error,
        ),
      );
      if (_pipelineLogs.length > 120) {
        _pipelineLogs.removeRange(120, _pipelineLogs.length);
      }
    });
  }

  List<Map<String, dynamic>> _figureAssetsOf(ProblemBankQuestion q) {
    final raw = q.meta['figure_assets'];
    if (raw is! List) return const <Map<String, dynamic>>[];
    return raw
        .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(
              (e as Map).map((k, dynamic v) => MapEntry('$k', v)),
            ))
        .toList(growable: false);
  }

  Map<String, dynamic>? _latestFigureAssetOf(ProblemBankQuestion q) {
    final assets = _figureAssetsOf(q);
    if (assets.isEmpty) return null;
    assets.sort((a, b) {
      final aa = '${a['created_at'] ?? ''}';
      final bb = '${b['created_at'] ?? ''}';
      return bb.compareTo(aa);
    });
    return assets.first;
  }

  List<Map<String, dynamic>> _orderedFigureAssetsOf(ProblemBankQuestion q) {
    final assets = _figureAssetsOf(q);
    if (assets.isEmpty) return assets;
    assets.sort((a, b) {
      final aa = '${a['created_at'] ?? ''}';
      final bb = '${b['created_at'] ?? ''}';
      return bb.compareTo(aa);
    });
    final byIndex = <int, Map<String, dynamic>>{};
    for (final asset in assets) {
      final index = int.tryParse('${asset['figure_index'] ?? ''}');
      if (index == null || index <= 0) continue;
      byIndex.putIfAbsent(index, () => asset);
    }
    if (byIndex.isNotEmpty) {
      final keys = byIndex.keys.toList()..sort();
      return keys.map((k) => byIndex[k]!).toList(growable: false);
    }
    return <Map<String, dynamic>>[assets.first];
  }

  String _figurePreviewUrlForPath(String questionId, String path) {
    final safePath = path.trim();
    if (safePath.isEmpty) return '';
    final map = _figurePreviewUrlsByPath[questionId];
    if (map != null && map.containsKey(safePath)) {
      return (map[safePath] ?? '').trim();
    }
    if (_figurePreviewPaths[questionId] == safePath) {
      return (_figurePreviewUrls[questionId] ?? '').trim();
    }
    return '';
  }

  bool _isFigureAssetApproved(Map<String, dynamic>? asset) {
    if (asset == null) return false;
    return asset['approved'] == true;
  }

  String _figureAssetStateText(Map<String, dynamic>? asset) {
    if (asset == null) return '생성본 없음';
    final approved = _isFigureAssetApproved(asset);
    final status = '${asset['status'] ?? ''}'.trim();
    if (approved) return '승인됨';
    if (status.isNotEmpty) return '검수 필요 ($status)';
    return '검수 필요';
  }

  Future<void> _prefetchFigurePreviewUrls(
      List<ProblemBankQuestion> questions) async {
    final updates = <String, String>{};
    final pathUpdates = <String, String>{};
    final byPathUpdates = <String, Map<String, String>>{};
    for (final q in questions) {
      final assets = _orderedFigureAssetsOf(q);
      if (assets.isEmpty) {
        updates[q.id] = '';
        pathUpdates[q.id] = '';
        byPathUpdates[q.id] = <String, String>{};
        continue;
      }

      final pathMap = <String, String>{};
      for (final asset in assets) {
        final bucket = '${asset['bucket'] ?? ''}'.trim();
        final path = '${asset['path'] ?? ''}'.trim();
        if (bucket.isEmpty || path.isEmpty) continue;
        try {
          final signed = await _service.createStorageSignedUrl(
            bucket: bucket,
            path: path,
            expiresInSeconds: 60 * 60 * 24,
          );
          if (signed.isNotEmpty) {
            pathMap[path] = signed;
          }
        } catch (_) {
          // 미리보기 URL 발급 실패는 무시한다.
        }
      }
      final latest = _latestFigureAssetOf(q);
      final latestPath = '${latest?['path'] ?? ''}'.trim();
      if (latestPath.isNotEmpty && pathMap.containsKey(latestPath)) {
        updates[q.id] = pathMap[latestPath] ?? '';
        pathUpdates[q.id] = latestPath;
      } else {
        updates[q.id] = '';
        pathUpdates[q.id] = '';
      }
      byPathUpdates[q.id] = pathMap;
    }
    if (!mounted ||
        (updates.isEmpty && pathUpdates.isEmpty && byPathUpdates.isEmpty)) {
      return;
    }
    setState(() {
      for (final e in updates.entries) {
        if (e.value.isEmpty) {
          _figurePreviewUrls.remove(e.key);
        } else {
          _figurePreviewUrls[e.key] = e.value;
        }
      }
      for (final e in pathUpdates.entries) {
        if (e.value.isEmpty) {
          _figurePreviewPaths.remove(e.key);
        } else {
          _figurePreviewPaths[e.key] = e.value;
        }
      }
      for (final e in byPathUpdates.entries) {
        final map = e.value;
        if (map.isEmpty) {
          _figurePreviewUrlsByPath.remove(e.key);
        } else {
          _figurePreviewUrlsByPath[e.key] = Map<String, String>.from(map);
        }
      }
    });
  }

  Future<void> _requestFigureGeneration(ProblemBankQuestion q) async {
    final academyId = _academyId;
    final doc = _activeDocument;
    if (academyId == null || doc == null) return;
    if (_figureGenerating.contains(q.id)) return;
    setState(() {
      _figureGenerating.add(q.id);
      _isFigurePolling = true;
    });
    _ensurePolling();
    _appendPipelineLog('figure', '${q.questionNumber}번 AI 그림 생성 요청');
    try {
      var job = await _service.createFigureJob(
        academyId: academyId,
        documentId: doc.id,
        questionId: q.id,
        forceRegenerate: true,
      );
      for (var i = 0; i < 60; i += 1) {
        if (job.isTerminal) break;
        await Future<void>.delayed(const Duration(seconds: 2));
        final latest = await _service.getFigureJob(
          academyId: academyId,
          jobId: job.id,
        );
        if (latest == null) break;
        job = latest;
      }
      if (!job.isTerminal) {
        _appendPipelineLog(
          'figure',
          '${q.questionNumber}번 생성 작업이 대기열에 남아 있습니다. 잠시 후 자동 반영됩니다.',
        );
        _showSnack('${q.questionNumber}번 AI 그림 생성이 큐에 등록되었습니다.');
        return;
      }
      if (job.status == 'failed') {
        _appendPipelineLog(
          'figure',
          '${q.questionNumber}번 생성 실패: ${job.errorMessage.isNotEmpty ? job.errorMessage : job.errorCode}',
          error: true,
        );
        _showSnack(
          '${q.questionNumber}번 AI 그림 생성 실패: ${job.errorMessage.isNotEmpty ? job.errorMessage : job.errorCode}',
          error: true,
        );
        return;
      }
      await _reloadQuestions();
      _appendPipelineLog(
          'figure', '${q.questionNumber}번 생성 완료 (${job.status})');
      _showSnack('${q.questionNumber}번 AI 그림 생성 완료');
    } catch (e) {
      _appendPipelineLog('figure', '${q.questionNumber}번 생성 예외: $e',
          error: true);
      _showSnack('${q.questionNumber}번 AI 그림 생성 실패: $e', error: true);
    } finally {
      if (mounted) {
        setState(() {
          _figureGenerating.remove(q.id);
        });
      }
    }
  }

  Future<void> _toggleFigureAssetApproval(
    ProblemBankQuestion q,
    Map<String, dynamic> asset,
    bool approved,
  ) async {
    final currentAssets = _figureAssetsOf(q);
    if (currentAssets.isEmpty) return;
    final targetId = '${asset['id'] ?? ''}'.trim();
    final targetPath = '${asset['path'] ?? ''}'.trim();
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final updatedAssets = currentAssets.map((item) {
      final sameId = targetId.isNotEmpty && '${item['id'] ?? ''}' == targetId;
      final samePath =
          targetPath.isNotEmpty && '${item['path'] ?? ''}' == targetPath;
      if (!sameId && !samePath) return item;
      return <String, dynamic>{
        ...item,
        'approved': approved,
        'review_required': !approved,
        'reviewed_at': nowIso,
      };
    }).toList(growable: false);
    final updatedMeta = <String, dynamic>{
      ...q.meta,
      'figure_assets': updatedAssets,
      'figure_review_required': updatedAssets.any((e) => e['approved'] != true),
    };
    try {
      await _service.updateQuestionReview(
        questionId: q.id,
        isChecked: q.isChecked,
        meta: updatedMeta,
      );
      if (!mounted) return;
      setState(() {
        _questions = _questions
            .map((item) =>
                item.id == q.id ? item.copyWith(meta: updatedMeta) : item)
            .toList(growable: false);
      });
      _showSnack(
        approved
            ? '${q.questionNumber}번 AI 그림을 승인했습니다.'
            : '${q.questionNumber}번 AI 그림 승인을 해제했습니다.',
      );
    } catch (e) {
      _showSnack('AI 그림 승인 상태 저장 실패: $e', error: true);
    }
  }

  Future<void> _bootstrap() async {
    _appendPipelineLog('init', '문제은행 초기화 시작');
    try {
      await _service.ensurePipelineSchema();
      _appendPipelineLog('init', '파이프라인 스키마 확인 완료');
      final academyId = await _service.resolveAcademyId();
      _appendPipelineLog('init', 'academy_id 확인: $academyId');
      final docs = await _service.listRecentDocuments(academyId: academyId);
      if (!mounted) return;
      setState(() {
        _academyId = academyId;
        _schemaMissing = false;
        _academyMissing = false;
        _documents = docs;
        _activeDocument = docs.isNotEmpty ? docs.first : null;
        _statusText = docs.isEmpty ? '업로드할 HWPX를 선택하세요.' : '문서를 선택해 주세요.';
      });
      _appendPipelineLog('init', '최근 문서 ${docs.length}건 로드');
      if (_activeDocument != null) {
        await _loadDocumentContext(_activeDocument!.id);
      }
    } on ProblemBankSchemaMissingException catch (e) {
      _appendPipelineLog('init', e.message, error: true);
      if (!mounted) return;
      setState(() {
        _schemaMissing = true;
        _academyMissing = false;
        _statusText = e.message;
      });
    } on AcademyIdNotFoundException catch (e) {
      _appendPipelineLog('init', e.message, error: true);
      if (!mounted) return;
      setState(() {
        _schemaMissing = false;
        _academyMissing = true;
        _statusText = e.message;
      });
    } catch (e) {
      _appendPipelineLog('init', '초기화 예외: $e', error: true);
      if (!mounted) return;
      setState(() {
        _statusText = '초기화 실패: $e';
      });
    } finally {
      _appendPipelineLog('init', '초기화 종료');
      if (mounted) {
        setState(() {
          _bootstrapLoading = false;
        });
      }
    }
  }

  Future<void> _refreshDocuments() async {
    final academyId = _academyId;
    if (academyId == null || academyId.isEmpty) return;
    try {
      _appendPipelineLog('doc', '문서 목록 새로고침 시작');
      final docs = await _service.listRecentDocuments(academyId: academyId);
      if (!mounted) return;
      setState(() {
        _documents = docs;
        if (_activeDocument == null && docs.isNotEmpty) {
          _activeDocument = docs.first;
        } else if (_activeDocument != null &&
            !docs.any((d) => d.id == _activeDocument!.id)) {
          _activeDocument = docs.isEmpty ? null : docs.first;
        }
      });
      _appendPipelineLog('doc', '문서 목록 ${docs.length}건 갱신');
    } on ProblemBankSchemaMissingException catch (e) {
      _appendPipelineLog('doc', e.message, error: true);
      if (!mounted) return;
      setState(() {
        _schemaMissing = true;
        _statusText = e.message;
      });
    } catch (e) {
      _appendPipelineLog('doc', '문서 새로고침 실패: $e', error: true);
      _showSnack('문서 목록 새로고침 실패: $e', error: true);
    }
  }

  Future<void> _resetPipelineData() async {
    if (_isResetting || _isUploading || _isExtracting || _isExporting) return;
    final academyId = _academyId;
    if (academyId == null || academyId.isEmpty) {
      _showSnack('academy_id를 찾을 수 없습니다.', error: true);
      return;
    }

    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) {
            return AlertDialog(
              backgroundColor: _panel,
              title: const Text(
                '작업 리셋',
                style: TextStyle(color: _text),
              ),
              content: const Text(
                '이 학원의 문제은행 문서/추출/검수/PDF 내보내기 이력을 모두 삭제합니다.\n'
                '기존 작업 내용은 복구할 수 없습니다. 계속할까요?',
                style: TextStyle(color: _textSub, fontSize: 13),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text(
                    '취소',
                    style: TextStyle(color: _textSub),
                  ),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFDE6A73),
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('삭제'),
                ),
              ],
            );
          },
        ) ??
        false;
    if (!confirmed) return;

    _appendPipelineLog('reset', '작업 리셋 시작');
    if (!mounted) return;
    setState(() {
      _isResetting = true;
      _statusText = '이전 작업 데이터를 삭제하는 중입니다...';
    });

    try {
      final result = await _service.resetPipelineData(academyId: academyId);
      _pollTimer?.cancel();
      _pollTimer = null;
      if (!mounted) return;
      setState(() {
        _documents = <ProblemBankDocument>[];
        _activeDocument = null;
        _activeExtractJob = null;
        _activeExportJob = null;
        _questions = <ProblemBankQuestion>[];
        _figurePreviewUrls.clear();
        _figurePreviewPaths.clear();
        _figurePreviewUrlsByPath.clear();
        _figureGenerating.clear();
        _scoreDrafts.clear();
        _scoreSaving.clear();
        _isFigurePolling = false;
        _hasExtracted = false;
        _hasExported = false;
        _isUploading = false;
        _isExtracting = false;
        _isExporting = false;
        _showLowConfidenceOnly = false;
        _queuedLongWaitWarned = false;
        _lastExtractStatus = null;
        _lastExportStatus = null;
        _statusText = '이전 작업을 초기화했습니다. 새 HWPX를 업로드하세요.';
      });
      _appendPipelineLog(
        'reset',
        '초기화 완료: 문서 ${result.documentCount}건 · 추출잡 ${result.extractJobCount}건 · 문항 ${result.questionCount}건 · 출력 ${result.exportCount}건 · 스토리지 ${result.storageObjectCount}개',
      );
      _showSnack('이전 작업 데이터가 삭제되었습니다.');
    } catch (e) {
      _appendPipelineLog('reset', '작업 리셋 실패: $e', error: true);
      _showSnack('작업 리셋 실패: $e', error: true);
    } finally {
      if (mounted) {
        setState(() {
          _isResetting = false;
        });
      }
      unawaited(_refreshDocuments());
    }
  }

  Future<void> _loadDocumentContext(String documentId) async {
    final academyId = _academyId;
    if (academyId == null || academyId.isEmpty) return;
    try {
      _appendPipelineLog('doc', '문서 컨텍스트 로드: $documentId');
      final summary = await _service.loadDocumentSummary(
        academyId: academyId,
        documentId: documentId,
      );
      if (summary == null) {
        if (!mounted) return;
        setState(() {
          _statusText = '문서 정보를 찾을 수 없습니다.';
        });
        return;
      }
      final questions = await _service.listQuestions(
        academyId: academyId,
        documentId: documentId,
      );
      if (!mounted) return;
      final extractStatus = summary.latestExtractJob?.status ?? '';
      final exportStatus = summary.latestExportJob?.status ?? '';
      final figureJobsQueuedHint = int.tryParse(
              '${summary.latestExtractJob?.resultSummary['figureJobsQueued'] ?? 0}') ??
          0;
      setState(() {
        _activeDocument = summary.document;
        _activeExtractJob = summary.latestExtractJob;
        _activeExportJob = summary.latestExportJob;
        _questions = questions;
        _figurePreviewUrls.clear();
        _figurePreviewPaths.clear();
        _figurePreviewUrlsByPath.clear();
        _figureGenerating.clear();
        _scoreDrafts.clear();
        _scoreSaving.clear();
        _isFigurePolling = false;
        _hasExtracted = questions.isNotEmpty;
        _isExtracting =
            extractStatus == 'queued' || extractStatus == 'extracting';
        _isExporting = exportStatus == 'queued' || exportStatus == 'rendering';
        _hasExported = exportStatus == 'completed';
        _lastExtractStatus = extractStatus.isEmpty ? null : extractStatus;
        _lastExportStatus = exportStatus.isEmpty ? null : exportStatus;
        _isFigurePolling = figureJobsQueuedHint > 0;
        _statusText = _formatStatusText(
          extractStatus: extractStatus,
          exportStatus: exportStatus,
          questionCount: questions.length,
        );
      });
      _appendPipelineLog(
        'doc',
        '문서 로드 완료: 문항 ${questions.length}건, extract=$extractStatus, export=$exportStatus',
      );
      unawaited(_prefetchFigurePreviewUrls(questions));
      unawaited(_syncFigurePollingForActiveDocument());
      _ensurePolling();
    } catch (e) {
      _appendPipelineLog('doc', '문서 컨텍스트 로드 실패: $e', error: true);
      _showSnack('문서 컨텍스트 로드 실패: $e', error: true);
    }
  }

  String _formatStatusText({
    required String extractStatus,
    required String exportStatus,
    required int questionCount,
  }) {
    if (extractStatus == 'extracting' || extractStatus == 'queued') {
      return '한글/수식 추출이 진행 중입니다...';
    }
    if (extractStatus == 'failed') {
      return '추출이 실패했습니다. 재시도를 진행해 주세요.';
    }
    if (exportStatus == 'rendering' || exportStatus == 'queued') {
      return 'PDF 생성 작업이 진행 중입니다...';
    }
    if (questionCount > 0) {
      return '추출 결과 $questionCount문항을 불러왔습니다.';
    }
    return '문서를 업로드하고 추출을 시작하세요.';
  }

  Future<void> _pickAndUploadHwpx() async {
    if (_isResetting || _isUploading || _isExtracting || _isExporting) return;
    if (_schemaMissing) {
      _showSnack(
        'DB 마이그레이션이 먼저 필요합니다: 20260324193000_problem_bank_pipeline.sql',
        error: true,
      );
      return;
    }
    final academyId = _academyId;
    if (academyId == null || academyId.isEmpty) {
      _showSnack(
        'academy_id를 찾을 수 없습니다. memberships 소속 정보를 확인해주세요.',
        error: true,
      );
      return;
    }
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowMultiple: false,
      allowedExtensions: const ['hwpx'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.single;
    final fileName = file.name.trim().isEmpty ? 'document.hwpx' : file.name;
    final bytes = file.bytes ?? await _readBytesFromPath(file.path);
    if (bytes == null || bytes.isEmpty) {
      _showSnack('파일 데이터를 읽지 못했습니다.', error: true);
      return;
    }
    _appendPipelineLog(
      'upload',
      '파일 선택: $fileName (${bytes.length} bytes)',
    );

    setState(() {
      _isUploading = true;
      _hasExtracted = false;
      _hasExported = false;
      _statusText = 'HWPX 업로드 중...';
      _queuedLongWaitWarned = false;
      _lastExtractStatus = null;
      _lastExportStatus = null;
    });

    try {
      final uploaded = await _service.uploadDocument(
        academyId: academyId,
        bytes: bytes,
        originalName: fileName,
        examProfile: _templateToProfile(_selectedTemplate),
      );
      _appendPipelineLog('upload', '업로드 완료: document=${uploaded.id}');
      final extractJob = await _service.createExtractJob(
        academyId: academyId,
        documentId: uploaded.id,
      );
      _appendPipelineLog(
        'extract',
        '추출 잡 생성: ${extractJob.id} (${extractJob.status})',
      );
      await _refreshDocuments();
      if (!mounted) return;
      setState(() {
        _activeDocument = uploaded;
        _activeExtractJob = extractJob;
        _activeExportJob = null;
        _questions = <ProblemBankQuestion>[];
        _figurePreviewUrls.clear();
        _figurePreviewPaths.clear();
        _figurePreviewUrlsByPath.clear();
        _figureGenerating.clear();
        _scoreDrafts.clear();
        _scoreSaving.clear();
        _isFigurePolling = false;
        _isUploading = false;
        _isExtracting = true;
        _statusText = '추출 작업을 큐에 등록했습니다.';
      });
      _ensurePolling();
      _showSnack('업로드 및 추출 요청이 완료되었습니다.');
    } catch (e) {
      _appendPipelineLog('upload', '업로드/추출 요청 실패: $e', error: true);
      if (!mounted) return;
      setState(() {
        _isUploading = false;
        _isExtracting = false;
        _statusText = '업로드 실패';
      });
      _showSnack('업로드 실패: $e', error: true);
    }
  }

  Future<void> _openPasteImportDialog() async {
    if (_isResetting || _isUploading || _isExtracting || _isExporting) return;
    if (_schemaMissing) {
      _showSnack(
        'DB 마이그레이션이 먼저 필요합니다: 20260324193000_problem_bank_pipeline.sql',
        error: true,
      );
      return;
    }
    final academyId = _academyId;
    if (academyId == null || academyId.isEmpty) {
      _showSnack(
        'academy_id를 찾을 수 없습니다. memberships 소속 정보를 확인해주세요.',
        error: true,
      );
      return;
    }

    final textController = TextEditingController();
    final fileController = TextEditingController(text: 'manual_paste.txt');
    try {
      final payload = await showDialog<_PasteImportPayload>(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          return StatefulBuilder(
            builder: (context, setLocalState) {
              Future<void> readClipboard() async {
                final data = await Clipboard.getData('text/plain');
                final text = (data?.text ?? '').trim();
                if (text.isEmpty) return;
                textController.text = text;
                textController.selection = TextSelection.fromPosition(
                  TextPosition(offset: textController.text.length),
                );
                setLocalState(() {});
              }

              final charCount = textController.text.trim().length;
              return AlertDialog(
                backgroundColor: _panel,
                title: const Text(
                  '복사/붙여넣기 수동 추출',
                  style: TextStyle(color: _text),
                ),
                content: SizedBox(
                  width: 760,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '자동 추출이 어려운 문서는 한글에서 문제 텍스트를 복사해 직접 붙여넣을 수 있습니다.',
                        style: TextStyle(color: _textSub, fontSize: 12),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: fileController,
                        style: const TextStyle(color: _text),
                        decoration: InputDecoration(
                          labelText: '입력 이름(선택)',
                          labelStyle: const TextStyle(color: _textSub),
                          filled: true,
                          fillColor: _field,
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: _border),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: _accent),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: textController,
                        maxLines: 15,
                        style: const TextStyle(
                          color: _text,
                          fontSize: 13,
                          fontFamily: 'monospace',
                        ),
                        onChanged: (_) => setLocalState(() {}),
                        decoration: InputDecoration(
                          hintText:
                              '여기에 한글 문서 내용을 붙여넣으세요.\n예) 1. ...\n   ① ... ② ...\n또는 [24-1-A] ... 1 [4.00점] 형태',
                          hintStyle:
                              const TextStyle(color: _textSub, fontSize: 12),
                          filled: true,
                          fillColor: _field,
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: _border),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: _accent),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          TextButton.icon(
                            onPressed: () => unawaited(readClipboard()),
                            icon: const Icon(Icons.content_paste, size: 16),
                            label: const Text('클립보드 붙여넣기'),
                          ),
                          const Spacer(),
                          Text(
                            '$charCount자',
                            style:
                                const TextStyle(color: _textSub, fontSize: 11),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('취소'),
                  ),
                  FilledButton(
                    onPressed: textController.text.trim().isEmpty
                        ? null
                        : () {
                            Navigator.of(context).pop(
                              _PasteImportPayload(
                                rawText: textController.text,
                                sourceName: fileController.text.trim(),
                              ),
                            );
                          },
                    style: FilledButton.styleFrom(backgroundColor: _accent),
                    child: const Text('문항으로 등록'),
                  ),
                ],
              );
            },
          );
        },
      );
      if (payload == null) return;
      await _importPastedText(payload);
    } finally {
      textController.dispose();
      fileController.dispose();
    }
  }

  Future<void> _importPastedText(_PasteImportPayload payload) async {
    final academyId = _academyId;
    if (academyId == null || academyId.isEmpty) return;

    _appendPipelineLog('manual', '수동 입력 처리 시작');
    setState(() {
      _isUploading = true;
      _isExtracting = false;
      _hasExtracted = false;
      _hasExported = false;
      _statusText = '붙여넣기 텍스트를 문항으로 변환 중...';
      _lastExtractStatus = null;
      _lastExportStatus = null;
      _queuedLongWaitWarned = false;
    });

    try {
      final imported = await _service.importPastedText(
        academyId: academyId,
        rawText: payload.rawText,
        sourceName: payload.sourceName.trim().isEmpty
            ? 'manual_paste.txt'
            : payload.sourceName.trim(),
        examProfile: _templateToProfile(_selectedTemplate),
      );
      _appendPipelineLog(
        'manual',
        '수동 입력 완료: document=${imported.document.id}, ${imported.questionCount}문항',
      );
      await _refreshDocuments();
      if (!mounted) return;
      setState(() {
        _activeDocument = imported.document;
        _activeExtractJob = imported.extractJob;
        _activeExportJob = null;
        _figurePreviewUrls.clear();
        _figurePreviewPaths.clear();
        _figurePreviewUrlsByPath.clear();
        _figureGenerating.clear();
        _scoreDrafts.clear();
        _scoreSaving.clear();
        _isFigurePolling = false;
        _isUploading = false;
        _isExtracting = false;
        _hasExtracted = imported.questionCount > 0;
        _statusText = '수동 입력에서 ${imported.questionCount}문항을 생성했습니다.';
      });
      await _loadDocumentContext(imported.document.id);
      _showSnack('복사/붙여넣기 문항 ${imported.questionCount}건을 등록했습니다.');
    } catch (e) {
      _appendPipelineLog('manual', '수동 입력 처리 실패: $e', error: true);
      if (!mounted) return;
      setState(() {
        _isUploading = false;
        _isExtracting = false;
        _statusText = '수동 입력 처리 실패';
      });
      _showSnack('수동 입력 실패: $e', error: true);
    }
  }

  Future<Uint8List?> _readBytesFromPath(String? path) async {
    final p = (path ?? '').trim();
    if (p.isEmpty) return null;
    try {
      return File(p).readAsBytes();
    } catch (_) {
      return null;
    }
  }

  Future<void> _syncFigurePollingForActiveDocument() async {
    final academyId = _academyId;
    final doc = _activeDocument;
    if (academyId == null || academyId.isEmpty || doc == null) return;
    try {
      final jobs = await _service.listFigureJobs(
        academyId: academyId,
        documentId: doc.id,
        limit: 40,
      );
      final hasPending = jobs.any(
        (j) => j.status == 'queued' || j.status == 'rendering',
      );
      if (!mounted) return;
      if (_isFigurePolling != hasPending) {
        setState(() {
          _isFigurePolling = hasPending;
        });
      }
      _ensurePolling();
    } catch (_) {
      // figure polling 동기화 실패는 UI 진행을 막지 않는다.
    }
  }

  void _ensurePolling() {
    final hasPendingExtract = _activeExtractJob != null &&
        !_activeExtractJob!.isTerminal &&
        (_activeExtractJob!.status == 'queued' ||
            _activeExtractJob!.status == 'extracting');
    final hasPendingExport = _activeExportJob != null &&
        !_activeExportJob!.isTerminal &&
        (_activeExportJob!.status == 'queued' ||
            _activeExportJob!.status == 'rendering');
    final hasPendingFigure = _isFigurePolling || _figureGenerating.isNotEmpty;
    if (!hasPendingExtract && !hasPendingExport && !hasPendingFigure) {
      _pollTimer?.cancel();
      _pollTimer = null;
      return;
    }
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      unawaited(_pollJobs());
    });
    unawaited(_pollJobs());
  }

  Future<void> _pollJobs() async {
    final academyId = _academyId;
    if (academyId == null || academyId.isEmpty) return;

    bool shouldRefreshQuestions = false;
    String? nextStatusText;

    try {
      final extract = _activeExtractJob;
      if (extract != null &&
          (extract.status == 'queued' || extract.status == 'extracting')) {
        final latest = await _service.getExtractJob(
          academyId: academyId,
          jobId: extract.id,
        );
        if (!mounted || latest == null) return;
        final figureJobsQueuedHint =
            int.tryParse('${latest.resultSummary['figureJobsQueued'] ?? 0}') ??
                0;
        if (_lastExtractStatus != latest.status) {
          _appendPipelineLog(
            'extract',
            '상태 변경: ${_lastExtractStatus ?? '-'} -> ${latest.status}',
            error: latest.status == 'failed',
          );
          _lastExtractStatus = latest.status;
        }

        if (latest.status == 'queued') {
          final elapsed = DateTime.now().difference(latest.createdAt);
          if (elapsed >= const Duration(minutes: 2) && !_queuedLongWaitWarned) {
            _queuedLongWaitWarned = true;
            _appendPipelineLog(
              'extract',
              '큐 대기가 ${_formatElapsed(elapsed)} 지속됨. '
                  'gateway worker:pb-extract 실행 상태를 확인하세요.',
              error: true,
            );
            _showSnack(
              '추출이 오래 queued 상태입니다. gateway에서 worker:pb-extract가 실행 중인지 확인해주세요.',
              error: true,
            );
          }
        } else {
          _queuedLongWaitWarned = false;
        }

        setState(() {
          _activeExtractJob = latest;
          _isExtracting =
              latest.status == 'queued' || latest.status == 'extracting';
          if (figureJobsQueuedHint > 0) {
            _isFigurePolling = true;
          }
        });
        if (latest.isTerminal) {
          shouldRefreshQuestions = true;
          if (latest.status == 'failed') {
            _showSnack(
              '추출 실패: ${latest.errorMessage.isEmpty ? latest.errorCode : latest.errorMessage}',
              error: true,
            );
          }
          if (figureJobsQueuedHint > 0) {
            nextStatusText = '추출 완료 · AI 그림 생성 대기 중';
          } else {
            nextStatusText = latest.status == 'review_required'
                ? '저신뢰 문항이 있어 검수가 필요합니다.'
                : '추출이 완료되었습니다.';
          }
        }
      }

      final export = _activeExportJob;
      if (export != null &&
          (export.status == 'queued' || export.status == 'rendering')) {
        final latest = await _service.getExportJob(
          academyId: academyId,
          jobId: export.id,
        );
        if (!mounted || latest == null) return;
        if (_lastExportStatus != latest.status) {
          _appendPipelineLog(
            'export',
            '상태 변경: ${_lastExportStatus ?? '-'} -> ${latest.status}',
            error: latest.status == 'failed',
          );
          _lastExportStatus = latest.status;
        }
        setState(() {
          _activeExportJob = latest;
          _isExporting =
              latest.status == 'queued' || latest.status == 'rendering';
        });
        if (latest.isTerminal) {
          if (latest.status == 'completed') {
            _hasExported = true;
            _showSnack(
              latest.outputUrl.trim().isNotEmpty
                  ? 'PDF 생성 완료: ${latest.outputUrl}'
                  : 'PDF 생성이 완료되었습니다.',
            );
          } else if (latest.status == 'failed') {
            _showSnack(
              'PDF 생성 실패: ${latest.errorMessage.isEmpty ? latest.errorCode : latest.errorMessage}',
              error: true,
            );
          }
          nextStatusText ??= latest.status == 'completed'
              ? 'PDF 생성 완료'
              : 'PDF 생성 작업이 종료되었습니다.';
        }
      }

      final doc = _activeDocument;
      if (doc != null && (_isFigurePolling || _figureGenerating.isNotEmpty)) {
        final wasFigurePolling =
            _isFigurePolling || _figureGenerating.isNotEmpty;
        final figureJobs = await _service.listFigureJobs(
          academyId: academyId,
          documentId: doc.id,
          limit: 40,
        );
        final hasPendingFigure = figureJobs.any(
          (j) => j.status == 'queued' || j.status == 'rendering',
        );
        if (mounted) {
          setState(() {
            _isFigurePolling = hasPendingFigure;
            if (!hasPendingFigure) {
              _figureGenerating.clear();
            }
          });
        }
        if (wasFigurePolling && !hasPendingFigure) {
          final hasFailedFigure = figureJobs.any((j) => j.status == 'failed');
          shouldRefreshQuestions = true;
          nextStatusText ??=
              hasFailedFigure ? 'AI 그림 생성 종료(일부 실패)' : 'AI 그림 생성 완료';
          _appendPipelineLog(
            'figure',
            hasFailedFigure ? 'AI 그림 생성 작업 종료(실패 건 포함)' : 'AI 그림 생성 작업 종료(성공)',
            error: hasFailedFigure,
          );
        }
      }
    } catch (e) {
      _appendPipelineLog('poll', '작업 상태 조회 실패: $e', error: true);
      _showSnack('작업 상태 조회 실패: $e', error: true);
    }

    if (shouldRefreshQuestions && _activeDocument != null) {
      await _reloadQuestions();
    }
    if (!mounted) return;
    if (nextStatusText != null) {
      setState(() {
        _statusText = nextStatusText!;
      });
    }
    _ensurePolling();
  }

  Future<void> _reloadQuestions() async {
    final academyId = _academyId;
    final doc = _activeDocument;
    if (academyId == null || doc == null) return;
    try {
      final questions = await _service.listQuestions(
        academyId: academyId,
        documentId: doc.id,
      );
      if (!mounted) return;
      setState(() {
        _questions = questions;
        final ids = questions.map((q) => q.id).toSet();
        _scoreDrafts.removeWhere((id, _) => !ids.contains(id));
        _scoreSaving.removeWhere((id) => !ids.contains(id));
        _hasExtracted = questions.isNotEmpty;
        _isExtracting = false;
      });
      _appendPipelineLog('review', '문항 목록 갱신: ${questions.length}건');
      unawaited(_prefetchFigurePreviewUrls(questions));
      unawaited(_syncFigurePollingForActiveDocument());
    } catch (e) {
      _appendPipelineLog('review', '문항 갱신 실패: $e', error: true);
      _showSnack('문항 목록 갱신 실패: $e', error: true);
    }
  }

  Future<void> _setAllChecked(bool checked) async {
    final academyId = _academyId;
    final doc = _activeDocument;
    if (academyId == null || doc == null || _questions.isEmpty) return;
    try {
      await _service.bulkSetChecked(
        academyId: academyId,
        documentId: doc.id,
        isChecked: checked,
      );
      if (!mounted) return;
      setState(() {
        _questions = _questions
            .map((q) => q.copyWith(isChecked: checked))
            .toList(growable: false);
      });
    } catch (e) {
      _showSnack('일괄 체크 업데이트 실패: $e', error: true);
    }
  }

  Future<void> _toggleChecked(ProblemBankQuestion q, bool value) async {
    try {
      await _service.updateQuestionReview(
        questionId: q.id,
        isChecked: value,
      );
      if (!mounted) return;
      setState(() {
        _questions = _questions
            .map((e) => e.id == q.id ? e.copyWith(isChecked: value) : e)
            .toList(growable: false);
      });
    } catch (e) {
      _showSnack('문항 체크 업데이트 실패: $e', error: true);
    }
  }

  bool _isLowConfidence(ProblemBankQuestion q) {
    return q.confidence < 0.85 || q.flags.contains('low_confidence');
  }

  Future<void> _openReviewDialog(ProblemBankQuestion question) async {
    final stemCtrl = TextEditingController(text: question.renderedStem);
    final noteCtrl = TextEditingController(text: question.reviewerNotes);
    final editableEquationCount =
        question.equations.length > 12 ? 12 : question.equations.length;
    final equationCtrls = List<TextEditingController>.generate(
      editableEquationCount,
      (idx) {
        final eq = question.equations[idx];
        final seed =
            eq.latex.trim().isNotEmpty ? eq.latex.trim() : eq.raw.trim();
        return TextEditingController(text: seed);
      },
      growable: false,
    );
    String selectedType =
        question.questionType.isEmpty ? '미분류' : question.questionType;
    bool checked = question.isChecked;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: _panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: _border),
          ),
          title: Text(
            '${question.questionNumber}번 문항 검수',
            style: const TextStyle(color: _text, fontSize: 16),
          ),
          content: SizedBox(
            width: 660,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '문항 유형',
                    style: TextStyle(color: _textSub, fontSize: 12),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    height: 40,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: _field,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _border),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: StatefulBuilder(
                        builder: (context, setInnerState) {
                          return DropdownButton<String>(
                            value: selectedType,
                            dropdownColor: _panel,
                            isExpanded: true,
                            style: const TextStyle(color: _text, fontSize: 13),
                            items: const <String>[
                              '객관식',
                              '주관식',
                              '서술형',
                              '복합형',
                              '미분류',
                            ]
                                .map(
                                  (e) => DropdownMenuItem<String>(
                                    value: e,
                                    child: Text(e),
                                  ),
                                )
                                .toList(growable: false),
                            onChanged: (v) {
                              if (v == null) return;
                              setInnerState(() {
                                selectedType = v;
                              });
                            },
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    '문항 본문',
                    style: TextStyle(color: _textSub, fontSize: 12),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: stemCtrl,
                    maxLines: 8,
                    style: const TextStyle(color: _text, fontSize: 13),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: _field,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: _border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: _border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: _accent),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    '수식 LaTeX (추출/편집)',
                    style: TextStyle(color: _textSub, fontSize: 12),
                  ),
                  const SizedBox(height: 6),
                  if (equationCtrls.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: _field,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: _border),
                      ),
                      child: const Text(
                        '추출된 수식이 없습니다.',
                        style: TextStyle(color: _textSub, fontSize: 12),
                      ),
                    )
                  else ...[
                    for (var i = 0; i < equationCtrls.length; i += 1) ...[
                      if (i > 0) const SizedBox(height: 6),
                      TextField(
                        controller: equationCtrls[i],
                        maxLines: 2,
                        style: const TextStyle(
                          color: _text,
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                        decoration: InputDecoration(
                          labelText: '수식 ${i + 1}',
                          labelStyle:
                              const TextStyle(color: _textSub, fontSize: 11),
                          filled: true,
                          fillColor: _field,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: _border),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: _border),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: _accent),
                          ),
                        ),
                      ),
                    ],
                    if (question.equations.length > equationCtrls.length) ...[
                      const SizedBox(height: 6),
                      Text(
                        '수식이 많아 상위 ${equationCtrls.length}개만 편집 가능합니다.',
                        style: const TextStyle(color: _textSub, fontSize: 11),
                      ),
                    ],
                  ],
                  const SizedBox(height: 10),
                  const Text(
                    '검수 메모',
                    style: TextStyle(color: _textSub, fontSize: 12),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: noteCtrl,
                    maxLines: 2,
                    style: const TextStyle(color: _text, fontSize: 13),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: _field,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: _border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: _border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: _accent),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  StatefulBuilder(
                    builder: (context, setInnerState) {
                      return CheckboxListTile(
                        value: checked,
                        dense: true,
                        activeColor: _accent,
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          '검수 완료(선택)',
                          style: TextStyle(color: _textSub, fontSize: 12),
                        ),
                        controlAffinity: ListTileControlAffinity.leading,
                        onChanged: (v) {
                          setInnerState(() {
                            checked = v ?? false;
                          });
                        },
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('취소'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _accent),
              onPressed: () async {
                try {
                  final updatedEquations =
                      question.equations.asMap().entries.map((entry) {
                    final idx = entry.key;
                    final eq = entry.value;
                    if (idx >= equationCtrls.length) return eq;
                    final editedLatex = equationCtrls[idx].text.trim();
                    if (editedLatex.isEmpty) return eq;
                    return ProblemBankEquation(
                      token: eq.token,
                      raw: eq.raw,
                      latex: editedLatex,
                      mathml: eq.mathml,
                      confidence: eq.confidence,
                    );
                  }).toList(growable: false);
                  await _service.updateQuestionReview(
                    questionId: question.id,
                    isChecked: checked,
                    reviewerNotes: noteCtrl.text.trim(),
                    questionType: selectedType,
                    stem: stemCtrl.text.trim(),
                    equations: updatedEquations,
                  );
                  if (!mounted) return;
                  setState(() {
                    _questions = _questions
                        .map(
                          (q) => q.id == question.id
                              ? q.copyWith(
                                  isChecked: checked,
                                  reviewerNotes: noteCtrl.text.trim(),
                                  questionType: selectedType,
                                  stem: stemCtrl.text.trim(),
                                  equations: updatedEquations,
                                )
                              : q,
                        )
                        .toList(growable: false);
                  });
                  if (context.mounted) Navigator.of(context).pop(true);
                } catch (e) {
                  _showSnack('검수 저장 실패: $e', error: true);
                }
              },
              child: const Text('저장'),
            ),
          ],
        );
      },
    );
    if (result == true) {
      await _reloadQuestions();
      _showSnack('검수 내용이 저장되었습니다.');
    }
  }

  Future<void> _createExportJob() async {
    if (_isResetting || _isExporting) return;
    final academyId = _academyId;
    final doc = _activeDocument;
    if (academyId == null || doc == null) {
      _showSnack('선택된 문서가 없습니다.', error: true);
      return;
    }
    final selectedIds = _questions
        .where((q) => q.isChecked)
        .map((q) => q.id)
        .toList(growable: false);
    if (selectedIds.isEmpty) {
      _showSnack('선택된 문항이 없습니다. 문항을 1개 이상 선택해주세요.');
      return;
    }
    setState(() {
      _isExporting = true;
      _hasExported = false;
      _statusText = 'PDF 생성 작업을 등록 중입니다...';
    });
    _appendPipelineLog(
      'export',
      'PDF 생성 요청 준비: template=$_selectedTemplate, paper=$_selectedPaper, selected=${selectedIds.length}',
    );
    try {
      final job = await _service.createExportJob(
        academyId: academyId,
        documentId: doc.id,
        templateProfile: _templateToProfile(_selectedTemplate),
        paperSize: _selectedPaper,
        includeAnswerSheet: _includeAnswerSheet,
        includeExplanation: _includeExplanation,
        selectedQuestionIds: selectedIds,
        options: <String, dynamic>{
          'templateLabel': _selectedTemplate,
          'paper': _selectedPaper,
          'quality': <String, dynamic>{
            'atomicQuestionLayout': true,
            'choiceNoWrap': true,
            'figurePreserve': true,
          },
        },
      );
      if (!mounted) return;
      setState(() {
        _activeExportJob = job;
        _statusText = 'PDF 생성 작업이 큐에 등록되었습니다.';
      });
      _appendPipelineLog('export', 'PDF 잡 생성: ${job.id} (${job.status})');
      _ensurePolling();
    } catch (e) {
      _appendPipelineLog('export', 'PDF 요청 실패: $e', error: true);
      if (!mounted) return;
      setState(() {
        _isExporting = false;
      });
      _showSnack('PDF 생성 요청 실패: $e', error: true);
    }
  }

  Widget _buildSectionTitle(String title, {String? subtitle}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: _text,
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: const TextStyle(
              color: _textSub,
              fontSize: 12,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildStepChip({
    required int index,
    required String title,
    required bool active,
    required bool done,
  }) {
    final Color fg = done || active ? _text : _textSub;
    final Color bg = done
        ? _accent.withValues(alpha: 0.16)
        : (active ? const Color(0xFF2C3A34) : const Color(0xFF131A1D));
    final Color bd = done || active ? _accent : _border;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: bd),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 10,
            backgroundColor: done || active ? _accent : _field,
            child: Text(
              '$index',
              style: TextStyle(
                color: done || active ? Colors.white : _textSub,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              color: fg,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDocumentSelector() {
    final selectedId = _activeDocument?.id;
    final hasItems = _documents.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '문서',
          style: TextStyle(color: _textSub, fontSize: 12),
        ),
        const SizedBox(height: 6),
        Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: _field,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _border),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: hasItems ? selectedId : null,
              dropdownColor: _panel,
              isExpanded: true,
              hint: const Text(
                '업로드 문서를 선택하세요',
                style: TextStyle(color: _textSub, fontSize: 12),
              ),
              style: const TextStyle(
                color: _text,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
              items: _documents
                  .map(
                    (d) => DropdownMenuItem<String>(
                      value: d.id,
                      child: Text(
                        d.sourceFilename,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (value) async {
                if (value == null) return;
                final doc = _documents.firstWhere((d) => d.id == value);
                setState(() {
                  _activeDocument = doc;
                  _questions = <ProblemBankQuestion>[];
                  _scoreDrafts.clear();
                  _scoreSaving.clear();
                  _hasExtracted = false;
                });
                await _loadDocumentContext(doc.id);
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildProgressPanel() {
    final elapsed = _extractQueuedElapsed;
    final isQueuedLong =
        elapsed != null && elapsed >= const Duration(minutes: 2);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
      decoration: BoxDecoration(
        color: _field,
        borderRadius: BorderRadius.circular(8),
        border:
            Border.all(color: isQueuedLong ? const Color(0xFFDE6A73) : _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(
            value:
                _progressIndeterminate ? null : _progressValue.clamp(0.0, 1.0),
            minHeight: 7,
            backgroundColor: const Color(0xFF2A3034),
            color: isQueuedLong ? const Color(0xFFDE6A73) : _accent,
          ),
          const SizedBox(height: 8),
          Text(
            _progressLabel,
            style: TextStyle(
              color: isQueuedLong ? const Color(0xFFFFCDD2) : _textSub,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (isQueuedLong) ...[
            const SizedBox(height: 4),
            const Text(
              '추출 워커가 실행되지 않았을 수 있습니다. gateway에서 `npm run worker:pb-extract`를 확인하세요.',
              style: TextStyle(color: Color(0xFFFFCDD2), fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLogPanel() {
    return Container(
      width: double.infinity,
      height: 130,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _field,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _border),
      ),
      child: _pipelineLogs.isEmpty
          ? const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '작업 로그가 아직 없습니다.',
                style: TextStyle(color: _textSub, fontSize: 12),
              ),
            )
          : ListView.separated(
              itemCount: _pipelineLogs.length > 10 ? 10 : _pipelineLogs.length,
              separatorBuilder: (_, __) => const SizedBox(height: 4),
              itemBuilder: (context, index) {
                final item = _pipelineLogs[index];
                final ts =
                    '${item.at.hour.toString().padLeft(2, '0')}:${item.at.minute.toString().padLeft(2, '0')}:${item.at.second.toString().padLeft(2, '0')}';
                return Text(
                  '[$ts][${item.stage}] ${item.message}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: item.isError ? const Color(0xFFFFCDD2) : _textSub,
                    fontSize: 11.5,
                    fontFamily: 'monospace',
                  ),
                );
              },
            ),
    );
  }

  Widget _buildUploadPanel() {
    final busyText = _isResetting
        ? '이전 작업 초기화 중...'
        : _isUploading
            ? 'HWPX 업로드 중...'
            : (_isExtracting ? '한글/수식 추출 및 정규화 중...' : _statusText);
    return Container(
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionTitle(
            '1) HWPX 업로드/추출',
            subtitle: '원본 보존 + 문항/수식 정규화 + 비동기 추출 잡 실행',
          ),
          const SizedBox(height: 12),
          _buildDocumentSelector(),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: (_isUploading ||
                      _isResetting ||
                      _isExtracting ||
                      _schemaMissing ||
                      _academyMissing ||
                      _academyId == null ||
                      _academyId!.isEmpty)
                  ? null
                  : _pickAndUploadHwpx,
              style: FilledButton.styleFrom(backgroundColor: _accent),
              icon: _isUploading
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.upload_file_outlined, size: 17),
              label: Text(_isUploading ? '업로드 중...' : 'HWPX 업로드/추출'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: (_isUploading ||
                      _isResetting ||
                      _isExtracting ||
                      _schemaMissing ||
                      _academyMissing ||
                      _academyId == null ||
                      _academyId!.isEmpty)
                  ? null
                  : () => unawaited(_openPasteImportDialog()),
              style: OutlinedButton.styleFrom(
                foregroundColor: _textSub,
                side: const BorderSide(color: _border),
              ),
              icon: const Icon(Icons.content_paste_outlined, size: 17),
              label: const Text('복사/붙여넣기 수동 추출'),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: (_isUploading || _isExtracting || _isResetting)
                    ? const CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _accent,
                      )
                    : const Icon(Icons.check_circle, size: 14, color: _accent),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  busyText,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _textSub,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _buildProgressPanel(),
          if (_activeExtractJob != null) ...[
            const SizedBox(height: 8),
            Text(
              'extract_job: ${_activeExtractJob!.status} (retry ${_activeExtractJob!.retryCount}/${_activeExtractJob!.maxRetries})',
              style: const TextStyle(color: _textSub, fontSize: 11),
            ),
          ],
          const SizedBox(height: 10),
          const Text(
            '실행 로그',
            style: TextStyle(color: _textSub, fontSize: 12),
          ),
          const SizedBox(height: 6),
          _buildLogPanel(),
          if (_schemaMissing || _academyMissing) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF2A1B1F),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFDE6A73)),
              ),
              child: Text(
                _schemaMissing
                    ? '필수 마이그레이션을 적용한 뒤 앱을 다시 열어주세요.\n파일: supabase/migrations/20260324193000_problem_bank_pipeline.sql'
                    : '로그인 계정의 academy 소속을 찾지 못했습니다.\nmemberships.user_id 연결 상태를 확인해주세요.',
                style: const TextStyle(
                  color: Color(0xFFFFCDD2),
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDropdownField({
    required String label,
    required String value,
    required List<String> values,
    required void Function(String value) onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: _textSub,
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: _field,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _border),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: value,
              dropdownColor: _panel,
              isExpanded: true,
              style: const TextStyle(
                color: _text,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
              items: values
                  .map(
                    (e) => DropdownMenuItem<String>(
                      value: e,
                      child: Text(e),
                    ),
                  )
                  .toList(),
              onChanged: (v) {
                if (v == null) return;
                onChanged(v);
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTemplatePanel() {
    return Container(
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionTitle(
            '3) 양식 적용 및 출력',
            subtitle: '내신/수능/모의고사 프로파일에 맞춰 PDF 생성',
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _buildDropdownField(
                  label: '시험 양식',
                  value: _selectedTemplate,
                  values: _templateOptions,
                  onChanged: (v) => setState(() => _selectedTemplate = v),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 120,
                child: _buildDropdownField(
                  label: '용지',
                  value: _selectedPaper,
                  values: _paperOptions,
                  onChanged: (v) => setState(() => _selectedPaper = v),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _includeAnswerSheet,
                  activeColor: _accent,
                  title: const Text(
                    '정답지 포함',
                    style: TextStyle(color: _textSub, fontSize: 13),
                  ),
                  controlAffinity: ListTileControlAffinity.leading,
                  onChanged: (v) =>
                      setState(() => _includeAnswerSheet = v ?? false),
                ),
              ),
              Expanded(
                child: CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _includeExplanation,
                  activeColor: _accent,
                  title: const Text(
                    '해설 포함',
                    style: TextStyle(color: _textSub, fontSize: 13),
                  ),
                  controlAffinity: ListTileControlAffinity.leading,
                  onChanged: (v) =>
                      setState(() => _includeExplanation = v ?? false),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed:
                  (_isExporting || _isResetting) ? null : _createExportJob,
              style: FilledButton.styleFrom(backgroundColor: _accent),
              icon: _isExporting
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.picture_as_pdf_outlined, size: 17),
              label: Text(_isExporting ? 'PDF 생성 중...' : 'PDF 생성 요청'),
            ),
          ),
          if (_activeExportJob != null) ...[
            const SizedBox(height: 8),
            Text(
              'export_job: ${_activeExportJob!.status}'
              '${_activeExportJob!.pageCount > 0 ? ' · ${_activeExportJob!.pageCount}p' : ''}',
              style: const TextStyle(color: _textSub, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }

  String _normalizePreviewLine(String raw) {
    return raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String _normalizePreviewMultiline(String raw) {
    final src = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = src
        .split('\n')
        .map((line) => line.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    return lines.join('\n');
  }

  static const Map<String, String> _unicodeSuperscriptMap = {
    '⁰': '0',
    '¹': '1',
    '²': '2',
    '³': '3',
    '⁴': '4',
    '⁵': '5',
    '⁶': '6',
    '⁷': '7',
    '⁸': '8',
    '⁹': '9',
    '⁺': '+',
    '⁻': '-',
    '⁼': '=',
    '⁽': '(',
    '⁾': ')',
    'ⁿ': 'n',
    'ˣ': 'x',
  };

  static const Map<String, String> _unicodeSubscriptMap = {
    '₀': '0',
    '₁': '1',
    '₂': '2',
    '₃': '3',
    '₄': '4',
    '₅': '5',
    '₆': '6',
    '₇': '7',
    '₈': '8',
    '₉': '9',
    '₊': '+',
    '₋': '-',
    '₌': '=',
    '₍': '(',
    '₎': ')',
    'ₓ': 'x',
  };

  String _normalizeUnicodeScriptTokens(String input) {
    if (input.isEmpty) return input;
    final sb = StringBuffer();
    for (final rune in input.runes) {
      final ch = String.fromCharCode(rune);
      final sup = _unicodeSuperscriptMap[ch];
      if (sup != null) {
        sb.write('^{');
        sb.write(sup);
        sb.write('}');
        continue;
      }
      final sub = _unicodeSubscriptMap[ch];
      if (sub != null) {
        sb.write('_{');
        sb.write(sub);
        sb.write('}');
        continue;
      }
      sb.write(ch);
    }
    return sb.toString();
  }

  String _normalizeLatexPreview(String raw) {
    String out =
        _normalizeUnicodeScriptTokens(raw.replaceAll(RegExp(r'`+'), ''));
    out = out
        // 유니코드 수학 기호를 LaTeX 명령으로 정규화 (파싱 실패 방지)
        .replaceAll('×', r'\times ')
        .replaceAll('÷', r'\div ')
        .replaceAll('·', r'\cdot ')
        .replaceAll('∙', r'\cdot ')
        .replaceAll('−', '-')
        .replaceAll('≤', r'\le ')
        .replaceAll('≥', r'\ge ')
        // 유니코드 단일 분수 문자도 LaTeX 분수로 통일
        .replaceAll('¼', r'\frac{1}{4}')
        .replaceAll('½', r'\frac{1}{2}')
        .replaceAll('¾', r'\frac{3}{4}')
        .replaceAll('⅓', r'\frac{1}{3}')
        .replaceAll('⅔', r'\frac{2}{3}')
        .replaceAll('⅕', r'\frac{1}{5}')
        .replaceAll('⅖', r'\frac{2}{5}')
        .replaceAll('⅗', r'\frac{3}{5}')
        .replaceAll('⅘', r'\frac{4}{5}')
        .replaceAll('⅙', r'\frac{1}{6}')
        .replaceAll('⅚', r'\frac{5}{6}')
        .replaceAll('⅛', r'\frac{1}{8}')
        .replaceAll('⅜', r'\frac{3}{8}')
        .replaceAll('⅝', r'\frac{5}{8}')
        .replaceAll('⅞', r'\frac{7}{8}')
        .replaceAll(RegExp(r'\{rm\{([^}]*)\}\}it', caseSensitive: false),
            r'\\mathrm{$1}')
        .replaceAll(
            RegExp(r'rm\{([^}]*)\}it', caseSensitive: false), r'\\mathrm{$1}')
        .replaceAllMapped(
          RegExp(
            r'(^|[^\\])left\s*(?=[\[\]\(\)\{\}\|.])',
            caseSensitive: false,
          ),
          (m) => '${m.group(1) ?? ''}${r'\left'}',
        )
        .replaceAllMapped(
          RegExp(
            r'(^|[^\\])right\s*(?=[\[\]\(\)\{\}\|.])',
            caseSensitive: false,
          ),
          (m) => '${m.group(1) ?? ''}${r'\right'}',
        )
        .replaceAll(RegExp(r'\btimes\b', caseSensitive: false), r'\times ')
        .replaceAll(RegExp(r'\bdiv\b', caseSensitive: false), r'\div ')
        .replaceAll(RegExp(r'\ble\b', caseSensitive: false), r'\le ')
        .replaceAll(RegExp(r'\bge\b', caseSensitive: false), r'\ge ');

    for (int i = 0; i < 4; i += 1) {
      final next = out
          .replaceAllMapped(
            RegExp(r'\{([^{}]+)\}\s*\\over\s*\{([^{}]+)\}'),
            (m) => '\\frac{${m.group(1)!.trim()}}{${m.group(2)!.trim()}}',
          )
          .replaceAllMapped(
            RegExp(r'([\-]?\d+(?:\.\d+)?)\s*\\over\s*\{([^{}]+)\}'),
            (m) => '\\frac{${m.group(1)!.trim()}}{${m.group(2)!.trim()}}',
          )
          .replaceAllMapped(
            RegExp(r'([A-Za-z])\s*\\over\s*([A-Za-z0-9]+)'),
            (m) => '\\frac{${m.group(1)!.trim()}}{${m.group(2)!.trim()}}',
          );
      if (next == out) break;
      out = next;
    }

    out = out
        .replaceAll(RegExp(r'\\over'), '/')
        .replaceAll(RegExp(r'\\{2,}'), r'\')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return out;
  }

  String _sanitizeLatexForMathTex(String raw) {
    String out = _normalizeLatexPreview(raw);
    out = out
        .replaceAllMapped(
          RegExp(r'\\left\s*([\[\]\(\)\{\}\|])'),
          (m) {
            final d = m.group(1) ?? '';
            if (d == '{') return r'\left\{';
            if (d == '}') return r'\left\}';
            return r'\left' + d;
          },
        )
        .replaceAllMapped(
          RegExp(r'\\right\s*([\[\]\(\)\{\}\|])'),
          (m) {
            final d = m.group(1) ?? '';
            if (d == '{') return r'\right\{';
            if (d == '}') return r'\right\}';
            return r'\right' + d;
          },
        )
        .replaceAll(RegExp(r'\\left\{'), r'\left\{')
        .replaceAll(RegExp(r'\\right\}'), r'\right\}');
    out = _balanceCurlyBracesForPreview(out);

    final leftCount =
        RegExp(r'\\left(?=[\\\[\]\(\)\{\}\|.])').allMatches(out).length;
    final rightCount =
        RegExp(r'\\right(?=[\\\[\]\(\)\{\}\|.])').allMatches(out).length;
    if (leftCount != rightCount) {
      out = out.replaceAll(r'\left', '').replaceAll(r'\right', '');
    }
    return out.trim();
  }

  String _balanceCurlyBracesForPreview(String raw) {
    if (raw.isEmpty) return raw;
    final out = <String>[];
    final openIndices = <int>[];
    for (int i = 0; i < raw.length; i += 1) {
      final ch = raw[i];
      if (ch == '{') {
        openIndices.add(out.length);
        out.add(ch);
        continue;
      }
      if (ch == '}') {
        if (openIndices.isNotEmpty) {
          openIndices.removeLast();
          out.add(ch);
        }
        continue;
      }
      out.add(ch);
    }
    for (final idx in openIndices) {
      out[idx] = '';
    }
    return out.join();
  }

  bool _hasBalancedCurlyBraces(String raw) {
    int depth = 0;
    for (int i = 0; i < raw.length; i += 1) {
      final ch = raw[i];
      if (ch == '{') depth += 1;
      if (ch == '}') {
        depth -= 1;
        if (depth < 0) return false;
      }
    }
    return depth == 0;
  }

  bool _isLikelyLatexParseUnsafe(String raw) {
    if (raw.trim().isEmpty) return true;
    if (!_hasBalancedCurlyBraces(raw)) return true;
    final leftCount = RegExp(r'\\left').allMatches(raw).length;
    final rightCount = RegExp(r'\\right').allMatches(raw).length;
    if (leftCount != rightCount) return true;
    return false;
  }

  bool _containsFractionExpression(String raw) {
    return raw.contains(r'\frac') ||
        raw.contains(r'\dfrac') ||
        raw.contains(r'\tfrac') ||
        RegExp(r'(^|[^\\])\d+\s*/\s*\d+').hasMatch(raw);
  }

  bool _containsNestedFractionExpression(String raw) {
    if (!_containsFractionExpression(raw)) return false;
    return RegExp(r'\\left|\\right').hasMatch(raw) ||
        RegExp(r'\([^()]*\([^()]+\)').hasMatch(raw) ||
        RegExp(r'\[[^\[\]]*\[[^\[\]]+\]').hasMatch(raw);
  }

  String _latexToPlainPreview(String raw) {
    var out = raw;
    for (int i = 0; i < 4; i += 1) {
      final next = out.replaceAllMapped(
        RegExp(r'\\frac\s*\{([^{}]+)\}\s*\{([^{}]+)\}'),
        (m) => '${m.group(1)}/${m.group(2)}',
      );
      if (next == out) break;
      out = next;
    }
    out = out
        .replaceAll(r'\times', '×')
        .replaceAll(r'\div', '÷')
        .replaceAll(r'\le', '≤')
        .replaceAll(r'\ge', '≥')
        .replaceAll(RegExp(r'\\left|\\right'), '')
        .replaceAll(RegExp(r'\\mathrm\{([^{}]+)\}'), r'$1')
        .replaceAll(RegExp(r'[{}]'), '')
        .replaceAll(RegExp(r'\\'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return out;
  }

  bool _looksLikeMathCandidate(String raw) {
    final input = raw.trim();
    if (input.isEmpty) return false;
    if (RegExp(r'[가-힣]').hasMatch(input)) return false;
    return RegExp(r'[A-Za-z0-9=^_{}\\]|\\times|\\over|\\le|\\ge|\\frac|\\dfrac')
        .hasMatch(input);
  }

  bool _isPurePunctuationSegment(String raw) {
    final compact = raw.replaceAll(RegExp(r'\s+'), '');
    if (compact.isEmpty) return true;
    return RegExp(r'^[\.,;:!?<>\(\)\[\]\{\}\-~"' "'" r'`|\\/]+$')
        .hasMatch(compact);
  }

  void _appendPreviewMathToken(
    StringBuffer buffer,
    String latex, {
    required bool compactFractions,
  }) {
    if (_containsFractionExpression(latex)) {
      final boostedLatex = _promoteFractionsForPreview(latex);
      final fracMode = compactFractions ? r'\textstyle' : r'\displaystyle';
      buffer.write('\\($fracMode ');
      buffer.write(boostedLatex);
      buffer.write(r'\)');
      return;
    }
    buffer.write(r'\(');
    buffer.write(latex);
    buffer.write(r'\)');
  }

  String _promoteFractionsForPreview(String latex) {
    var out = latex;
    // \frac, \tfrac를 \dfrac로 승격해 분수 내부 숫자만 확대
    out = out.replaceAllMapped(
      RegExp(r'\\(?:dfrac|tfrac|frac)\s*(?=\{)'),
      (_) => r'\dfrac',
    );
    // 단순 숫자/숫자 형태는 디스플레이 분수로 승격
    out = out.replaceAllMapped(
      RegExp(r'(?<![\\\w])(-?\d+(?:\.\d+)?)\s*/\s*(-?\d+(?:\.\d+)?)(?![\w])'),
      (m) => r'\dfrac{${m.group(1) ?? ' '}}{${m.group(2) ?? ''}}',
    );
    return out;
  }

  String _buildTokenizedMathMarkup(
    String latex, {
    required bool compactFractions,
  }) {
    // 공백 기반 토큰 분해로 선택지 가로셀에서 수식 줄바꿈 기회를 늘린다.
    // 중괄호가 포함된 복합 수식은 분해하지 않고 원본 1토큰으로 유지한다.
    final hasStructuredCommand = RegExp(
      r'\\(?:left|right|frac|dfrac|sqrt|sum|int|overline|mathrm|text|begin|end)',
    ).hasMatch(latex);
    final hasScriptOrGrouping = RegExp(r'[{}^_]').hasMatch(latex);
    if (!latex.contains(' ') || hasStructuredCommand || hasScriptOrGrouping) {
      final one = StringBuffer();
      _appendPreviewMathToken(one, latex, compactFractions: compactFractions);
      return one.toString();
    }
    final parts = latex
        .split(RegExp(r'\s+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    if (parts.length <= 1) {
      final one = StringBuffer();
      _appendPreviewMathToken(one, latex, compactFractions: compactFractions);
      return one.toString();
    }
    final tokenized = <String>[];
    for (final token in parts) {
      final isOperatorToken = RegExp(
        r'^(?:=|[+\-*/<>]|\\times|\\div|\\cdot|\\le|\\ge)+$',
      ).hasMatch(token);
      final tokenIsMath = isOperatorToken || _looksLikeMathCandidate(token);
      if (tokenIsMath &&
          !_isPurePunctuationSegment(token) &&
          !_isLikelyLatexParseUnsafe(token)) {
        final sb = StringBuffer();
        _appendPreviewMathToken(sb, token, compactFractions: compactFractions);
        tokenized.add(sb.toString());
      } else {
        tokenized.add(token);
      }
    }
    if (tokenized.isEmpty) {
      final one = StringBuffer();
      _appendPreviewMathToken(one, latex, compactFractions: compactFractions);
      return one.toString();
    }
    return tokenized.join(' ');
  }

  String _toPreviewMathMarkup(
    String raw, {
    bool forceMathTokenWrap = false,
    bool compactFractions = true,
  }) {
    final input = raw;
    if (input.trim().isEmpty) return '';
    final buffer = StringBuffer();
    int lastIndex = 0;
    final nonKoreanSegments = RegExp(r'[^가-힣]+');
    for (final match in nonKoreanSegments.allMatches(input)) {
      if (match.start > lastIndex) {
        buffer.write(input.substring(lastIndex, match.start));
      }
      final segment = input.substring(match.start, match.end);
      final leading = RegExp(r'^\s*').stringMatch(segment) ?? '';
      final trailing = RegExp(r'\s*$').stringMatch(segment) ?? '';
      final core = segment.trim();
      if (core.isEmpty) {
        buffer.write(segment);
        lastIndex = match.end;
        continue;
      }
      final latex = _sanitizeLatexForMathTex(core);
      final compact = latex.replaceAll(RegExp(r'[\s\.,;:!?()\[\]<>]'), '');
      final hasMathOperator = RegExp(
              r'[=^_]|[+\-*/<>]|\\times|\\over|\\div|\\le|\\ge|\\frac|\\dfrac|\\sqrt|\\left|\\right|\\sum|\\int|\\pi|\\theta|\\sin|\\cos|\\tan|\\log')
          .hasMatch(latex);
      final hasMathToken =
          hasMathOperator || RegExp(r'[A-Za-z0-9]').hasMatch(latex);
      final looksJustNumbering =
          RegExp(r'^[①②③④⑤⑥⑦⑧⑨⑩0-9.\-]+$').hasMatch(compact);
      final isViewMarker = RegExp(r'보\s*기').hasMatch(core);
      final shouldWrap = compact.isNotEmpty &&
          (forceMathTokenWrap || !looksJustNumbering) &&
          !isViewMarker &&
          !_isPurePunctuationSegment(latex) &&
          _looksLikeMathCandidate(latex) &&
          hasMathToken &&
          !_isLikelyLatexParseUnsafe(latex);
      if (shouldWrap) {
        buffer.write(leading);
        if (forceMathTokenWrap) {
          buffer.write(
            _buildTokenizedMathMarkup(
              latex,
              compactFractions: compactFractions,
            ),
          );
        } else {
          _appendPreviewMathToken(
            buffer,
            latex,
            compactFractions: compactFractions,
          );
        }
        buffer.write(trailing);
      } else {
        buffer.write(leading);
        if (_looksLikeMathCandidate(latex) && forceMathTokenWrap) {
          final fallbackLatex =
              _sanitizeLatexForMathTex(_latexToPlainPreview(latex));
          if (fallbackLatex.isNotEmpty &&
              !_isPurePunctuationSegment(fallbackLatex) &&
              !_isLikelyLatexParseUnsafe(fallbackLatex)) {
            _appendPreviewMathToken(
              buffer,
              fallbackLatex,
              compactFractions: compactFractions,
            );
          } else {
            buffer.write(_latexToPlainPreview(latex));
          }
        } else if (_looksLikeMathCandidate(latex)) {
          buffer.write(_latexToPlainPreview(latex));
        } else {
          buffer.write(core);
        }
        buffer.write(trailing);
      }
      lastIndex = match.end;
    }
    if (lastIndex < input.length) {
      buffer.write(input.substring(lastIndex));
    }
    return buffer.toString();
  }

  double _choicePreviewLineHeight(String raw) {
    final latex = _sanitizeLatexForMathTex(raw);
    if (_containsNestedFractionExpression(latex)) return 1.84;
    if (_containsFractionExpression(latex)) return 1.72;
    return 1.52;
  }

  double _denseMathLineHeight(String raw, {double normal = 1.58}) {
    final latex = _sanitizeLatexForMathTex(raw);
    if (_containsNestedFractionExpression(latex)) return normal + 0.30;
    if (_containsFractionExpression(latex)) return normal + 0.18;
    if (RegExp(r'[A-Za-z0-9]').hasMatch(latex)) return normal + 0.04;
    return normal;
  }

  double? _scorePointOf(ProblemBankQuestion q) {
    final raw = q.meta['score_point'];
    if (raw == null) return null;
    if (raw is num) {
      return raw > 0 ? raw.toDouble() : null;
    }
    final parsed = double.tryParse('$raw');
    if (parsed == null || parsed <= 0) return null;
    return parsed;
  }

  String _scorePointInputText(double value) {
    final rounded = value.roundToDouble();
    return rounded == value ? rounded.toInt().toString() : value.toString();
  }

  String _scoreDraftFor(ProblemBankQuestion q) {
    final draft = _scoreDrafts[q.id];
    if (draft != null) return draft;
    final score = _scorePointOf(q);
    if (score == null) return '';
    return _scorePointInputText(score);
  }

  double? _parseScoreDraft(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final cleaned = trimmed
        .replaceAll('점', '')
        .replaceAll(RegExp(r'[\[\]\(\)\{\}]'), '')
        .trim();
    if (cleaned.isEmpty) return null;
    final parsed = double.tryParse(cleaned);
    if (parsed == null || !parsed.isFinite || parsed <= 0) return null;
    return parsed;
  }

  Future<void> _saveScoreDraft(ProblemBankQuestion q) async {
    if (_scoreSaving.contains(q.id)) return;
    final raw = (_scoreDrafts[q.id] ?? _scoreDraftFor(q)).trim();
    if (raw.isNotEmpty && _parseScoreDraft(raw) == null) {
      _showSnack('배점은 숫자로 입력해 주세요. (예: 4 또는 4.5)', error: true);
      return;
    }
    final parsed = _parseScoreDraft(raw);
    setState(() {
      _scoreSaving.add(q.id);
    });
    try {
      final updatedMeta = Map<String, dynamic>.from(q.meta);
      if (parsed == null) {
        updatedMeta.remove('score_point');
      } else {
        final rounded = parsed.roundToDouble();
        updatedMeta['score_point'] =
            rounded == parsed ? rounded.toInt() : parsed;
      }
      await _service.updateQuestionReview(
        questionId: q.id,
        isChecked: q.isChecked,
        meta: updatedMeta,
      );
      if (!mounted) return;
      setState(() {
        _questions = _questions
            .map((item) =>
                item.id == q.id ? item.copyWith(meta: updatedMeta) : item)
            .toList(growable: false);
        _scoreDrafts[q.id] = parsed == null ? '' : _scorePointInputText(parsed);
      });
      _showSnack('배점을 저장했습니다.');
    } catch (e) {
      _showSnack('배점 저장 실패: $e', error: true);
    } finally {
      if (mounted) {
        setState(() {
          _scoreSaving.remove(q.id);
        });
      }
    }
  }

  bool _looksLikeBoxedStemLine(String line) {
    final input = _normalizePreviewLine(line);
    if (input.isEmpty) return false;
    if (RegExp(r'^\(단[,，:]?').hasMatch(input)) return true;
    if (RegExp(r'^\|.+\|').hasMatch(input)) return true;
    return false;
  }

  bool _looksLikeBoxedConditionStart(String line) {
    final input = _normalizePreviewLine(line);
    if (input.isEmpty) return false;
    if (RegExp(r'옆으로\s*이웃한').hasMatch(input)) return true;
    if (RegExp(r'바로\s*위의?\s*칸').hasMatch(input)) return true;
    if (RegExp(r'^\(단[,，:]?').hasMatch(input)) return true;
    if (RegExp(r'^\|.+\|').hasMatch(input)) return true;
    return false;
  }

  bool _looksLikeBoxedConditionContinuation(String line) {
    final input = _normalizePreviewLine(line);
    if (input.isEmpty) return false;
    if (RegExp(r'일\s*때').hasMatch(input)) return true;
    if (RegExp(r'예\)$').hasMatch(input)) return true;
    if (RegExp(r'바로\s*위의?\s*칸').hasMatch(input)) return true;
    if (_figureMarkerRegex.hasMatch(input)) return true;
    return false;
  }

  List<List<String>> _boxedStemGroups(String raw) {
    final lines = raw
        .split(RegExp(r'\r?\n'))
        .map(_normalizePreviewLine)
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (lines.isEmpty) return const <List<String>>[];
    final groups = <List<String>>[];
    List<String> current = <String>[];
    bool inBoxedRegion = false;
    for (final line in lines) {
      if (!inBoxedRegion && _looksLikeBoxedConditionStart(line)) {
        inBoxedRegion = true;
        current.add(line);
        continue;
      }
      if (inBoxedRegion) {
        if (_looksLikeBoxedConditionContinuation(line) ||
            _looksLikeBoxedStemLine(line) ||
            _figureMarkerRegex.hasMatch(line)) {
          current.add(line);
          continue;
        }
        if (current.isNotEmpty) {
          groups.add(List<String>.from(current));
        }
        current = <String>[];
        inBoxedRegion = false;
        continue;
      }
      if (_looksLikeBoxedStemLine(line)) {
        current.add(line);
        continue;
      }
      if (current.isNotEmpty) {
        if (current.length >= 2) {
          groups.add(List<String>.from(current));
        }
        current = <String>[];
      }
    }
    if (current.isNotEmpty && (inBoxedRegion || current.length >= 2)) {
      groups.add(List<String>.from(current));
    }
    return groups;
  }

  bool _isViewBlockQuestion(ProblemBankQuestion q) {
    final stem = q.renderedStem;
    if (q.flags.contains('view_block')) return true;
    if (RegExp(r'<\s*보\s*기>').hasMatch(stem)) return true;
    return RegExp(r'(^|\n)\s*[ㄱ-ㅎ]\.').hasMatch(stem);
  }

  static final _structuralMarkerRegex = RegExp(r'\[(박스시작|박스끝|문단)\]');

  List<String> _viewBlockPreviewLines(ProblemBankQuestion q, {int max = 6}) {
    final normalizedStem = _stripPreviewStemDecorations(
      q,
      _normalizePreviewMultiline(q.renderedStem),
    );
    final markerNormalized = normalizedStem
        .replaceAll(_structuralMarkerRegex, ' ')
        .replaceAll(RegExp(r'<\s*보\s*기>'), '<보기>');
    final lines = markerNormalized
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (lines.isEmpty) return const <String>[];
    final lastMarker = markerNormalized.lastIndexOf('<보기>');
    if (lastMarker >= 0) {
      final tail =
          markerNormalized.substring(lastMarker + '<보기>'.length).trim();
      final rawParts = tail.split(RegExp(r'(?=[ㄱ-ㅎ]\.)'));
      final parts = <String>[];
      for (final part in rawParts) {
        final trimmed = part.trim();
        if (trimmed.isEmpty) continue;
        if (RegExp(r'^[ㄱ-ㅎ]\.').hasMatch(trimmed)) {
          parts.add(trimmed);
        } else if (parts.isNotEmpty) {
          parts[parts.length - 1] = '${parts.last} $trimmed';
        }
        if (parts.length >= max) break;
      }
      if (parts.isNotEmpty) {
        return <String>['<보기>', ...parts];
      }
    }

    final markerIdx = lines.indexWhere((line) => line.contains('<보기>'));
    int start = markerIdx >= 0
        ? markerIdx + 1
        : lines.indexWhere((line) => RegExp(r'^[ㄱ-ㅎ]\.').hasMatch(line));
    if (start < 0) return const <String>[];

    final out = <String>[];
    if (markerIdx >= 0) out.add('<보기>');
    for (int i = start; i < lines.length; i += 1) {
      final line = lines[i];
      if (RegExp(r'^[①②③④⑤⑥⑦⑧⑨⑩]').hasMatch(line)) break;
      if (RegExp(r'^[ㄱ-ㅎ]\.').hasMatch(line)) {
        out.add(line);
      } else if (out.length > (markerIdx >= 0 ? 1 : 0)) {
        out[out.length - 1] = '${out.last} $line';
      }
      if (out.length >= max + (markerIdx >= 0 ? 1 : 0)) break;
    }
    return out;
  }

  String _stripPreviewStemDecorations(ProblemBankQuestion q, String raw) {
    var out = _normalizePreviewMultiline(raw);
    if (out.isEmpty) return '';
    // stem 시작부에 남은 고아 [박스끝]/[문단] 마커 제거
    out = out.replaceFirst(RegExp(r'^(\s*\[(문단|박스끝)\]\s*)+'), '');
    out = out.replaceAll(RegExp(r'^\$1\s*'), '');
    out = out.replaceAll(RegExp(r'\$1(?=<\s*보\s*기>)'), '');
    final qn = q.questionNumber.trim();
    if (qn.isNotEmpty) {
      final escaped = RegExp.escape(qn);
      final lines = out.split('\n');
      if (lines.isNotEmpty) {
        lines[0] = lines[0]
            .replaceFirst(RegExp('^\\s*$escaped\\s*[\\.)．]\\s*'), '')
            .replaceFirst(RegExp('^\\s*$escaped\\s+(?=[^\\s])'), '');
        out = lines
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty)
            .join('\n');
      }
    }
    // stem 끝부분에 남은 고아 [박스시작]/[문단] 마커 제거
    out = out.replaceFirst(RegExp(r'(\s*\[(문단|박스시작)\]\s*)+$'), '');
    return _normalizePreviewMultiline(out);
  }

  String _answerTextForPreview(ProblemBankQuestion q) {
    final raw = '${q.meta['answer_key'] ?? ''}'.trim();
    if (raw.isEmpty) return '';
    return raw
        .replaceFirst(RegExp(r'^\[?\s*정답\s*\]?\s*[:：]?\s*'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  bool _isObjectiveAnswerPreview(ProblemBankQuestion q, String answer) {
    final normalized = answer.trim();
    if (normalized.isEmpty) return false;
    final hasChoices = q.choices.length >= 2;
    final choiceLike = RegExp(
      r'^[①②③④⑤⑥⑦⑧⑨⑩](?:\s*[,/]\s*[①②③④⑤⑥⑦⑧⑨⑩])*$',
    ).hasMatch(normalized);
    final numericLike = RegExp(r'^(?:[1-9]|10)(?:\s*[,/]\s*(?:[1-9]|10))*$')
        .hasMatch(normalized);
    return hasChoices &&
        (choiceLike || numericLike || q.questionType.contains('객관식'));
  }

  Widget _buildAnswerPreviewPanel(ProblemBankQuestion q,
      {bool expanded = false}) {
    final answer = _answerTextForPreview(q);
    final isObjectiveAnswer = _isObjectiveAnswerPreview(q, answer);
    if (answer.isEmpty) {
      return const Text(
        '미추출',
        style: TextStyle(color: Color(0xFF7D8BA5), fontSize: 12.4),
      );
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F7FC),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: const Color(0xFFDDE4F1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '정답',
            style: TextStyle(
              color: Color(0xFF4A5875),
              fontSize: 12.2,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          LatexTextRenderer(
            _toPreviewMathMarkup(answer, forceMathTokenWrap: true),
            softWrap: true,
            enableDisplayMath: true,
            inlineMathScale: _previewMathScale,
            fractionInlineMathScale: _previewFractionMathScale,
            displayMathScale: _previewMathScale,
            blockVerticalPadding: _denseMathLineHeight(
                      answer,
                      normal: isObjectiveAnswer ? 1.34 : 1.4,
                    ) >=
                    1.7
                ? 1.0
                : 0.6,
            style: TextStyle(
              color: const Color(0xFF1E2D4A),
              fontSize: isObjectiveAnswer
                  ? (expanded ? 14.8 : 14.4)
                  : (expanded ? 13.6 : 13.2),
              height: _denseMathLineHeight(
                answer,
                normal: isObjectiveAnswer ? 1.34 : 1.4,
              ),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAnswerPreviewThumbnail(ProblemBankQuestion q,
      {bool expanded = false}) {
    return Container(
      height: expanded ? null : 114,
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF0E1518),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _border),
      ),
      padding: const EdgeInsets.all(8.5),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFFCFCFC),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFFD5D5D5)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
        child: SingleChildScrollView(
          physics: expanded
              ? const ClampingScrollPhysics()
              : const NeverScrollableScrollPhysics(),
          child: _buildAnswerPreviewPanel(q, expanded: expanded),
        ),
      ),
    );
  }

  Widget _buildFigurePreviewThumbnail(ProblemBankQuestion q,
      {bool expanded = false}) {
    final asset = _latestFigureAssetOf(q);
    final previewUrl = _figurePreviewUrls[q.id];
    final statusText = _figureAssetStateText(asset);
    return Container(
      height: expanded ? null : 156,
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF0E1518),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _border),
      ),
      padding: const EdgeInsets.all(8.5),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFFCFCFC),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFFD5D5D5)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
        child: SingleChildScrollView(
          physics: const ClampingScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                statusText,
                style: const TextStyle(
                  color: Color(0xFF4A5875),
                  fontSize: 11.6,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              if (asset == null)
                const Text(
                  '생성본이 없습니다. 생성 작업이 대기 중이거나 실패했을 수 있습니다.\n'
                  '(gateway worker:pb-figure 로그 확인)',
                  style: TextStyle(color: Color(0xFF6E7E96), fontSize: 12.1),
                )
              else if (previewUrl == null || previewUrl.isEmpty)
                const Text(
                  '이미지 미리보기 로딩 중...',
                  style: TextStyle(color: Color(0xFF6E7E96), fontSize: 12.2),
                )
              else
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.network(
                    previewUrl,
                    fit: BoxFit.contain,
                    height: expanded ? 260 : 94,
                    width: double.infinity,
                    errorBuilder: (_, __, ___) => const Text(
                      '이미지 로드 실패',
                      style: TextStyle(color: Color(0xFF9C5A5A), fontSize: 12),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static final RegExp _figureMarkerRegex =
      RegExp(r'\[(?:그림|도형|도표|표)\]', caseSensitive: false);

  Widget _buildStemTextPreviewLine(
    String text, {
    double fontSize = 13.4,
    double normalHeight = 1.58,
  }) {
    final normalized = _normalizePreviewMultiline(
        text.replaceAll(_structuralMarkerRegex, ' '));
    final lineHeight = _denseMathLineHeight(normalized, normal: normalHeight);
    return LatexTextRenderer(
      _toPreviewMathMarkup(normalized, forceMathTokenWrap: true),
      softWrap: true,
      enableDisplayMath: true,
      inlineMathScale: _previewMathScale,
      fractionInlineMathScale: _previewFractionMathScale,
      displayMathScale: _previewMathScale,
      blockVerticalPadding: lineHeight >= 1.82 ? 1.8 : 1.0,
      style: TextStyle(fontSize: fontSize, height: lineHeight),
    );
  }

  Widget _buildInlineFigureInStem(
    ProblemBankQuestion q, {
    Map<String, dynamic>? asset,
    bool expanded = false,
  }) {
    final effectiveAsset = asset ?? _latestFigureAssetOf(q);
    final assetPath = '${effectiveAsset?['path'] ?? ''}'.trim();
    final previewUrl = _figurePreviewUrlForPath(q.id, assetPath);
    final hasFigureAsset = effectiveAsset != null;
    final stemHead = _normalizePreviewLine(q.renderedStem)
        .replaceAll(_figureMarkerRegex, '')
        .trim();
    final hint = q.figureRefs
        .map(_normalizePreviewLine)
        .where((line) {
          if (line.isEmpty) return false;
          if (_figureMarkerRegex.hasMatch(line)) return false;
          final cleaned = line.replaceAll(_figureMarkerRegex, '').trim();
          if (cleaned.length < 4) return false;
          if (stemHead.contains(cleaned) || cleaned.contains(stemHead)) {
            return false;
          }
          return true;
        })
        .take(1)
        .toList(growable: false);
    final figureHeight = expanded ? 232.0 : 138.0;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (previewUrl.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.network(
                previewUrl,
                fit: BoxFit.contain,
                width: double.infinity,
                height: figureHeight,
                errorBuilder: (_, __, ___) => SizedBox(
                  height: figureHeight * 0.62,
                  child: const Center(
                    child: Text(
                      '그림 미리보기를 불러오지 못했습니다.',
                      style:
                          TextStyle(color: Color(0xFF906060), fontSize: 11.8),
                    ),
                  ),
                ),
              ),
            )
          else
            Container(
              alignment: Alignment.center,
              height: figureHeight * 0.62,
              decoration: BoxDecoration(
                color: const Color(0xFFFDFDFE),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: const Color(0xFFE5E8EF)),
              ),
              child: Text(
                _figureGenerating.contains(q.id) || _isFigurePolling
                    ? 'AI 그림 생성 중...'
                    : hasFigureAsset
                        ? '이미지 로딩 중...'
                        : '그림 생성본 없음',
                style: const TextStyle(
                  color: Color(0xFF6F7C95),
                  fontSize: 11.8,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          if (hint.isNotEmpty) ...[
            const SizedBox(height: 5),
            Text(
              hint.first,
              maxLines: expanded ? 3 : 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF5A6680),
                fontSize: 11.6,
                height: 1.32,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBoxedStemContainer({required List<Widget> children}) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFFFF),
        border: Border.all(color: const Color(0xFF3E3E3E), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _buildViewBlockContentLine(String line, {bool expanded = false}) {
    final normalized =
        _normalizePreviewLine(line.replaceAll(_structuralMarkerRegex, ' '));
    if (normalized.isEmpty || normalized == '<보기>') {
      return const SizedBox.shrink();
    }
    final itemMatch = RegExp(r'^([ㄱ-ㅎ①②③④⑤⑥⑦⑧⑨⑩]|\d{1,2})\s*[\.\)]\s*(.+)$')
        .firstMatch(normalized);
    final lineHeight = _denseMathLineHeight(normalized, normal: 1.76);
    final style = TextStyle(
      color: const Color(0xFF2D2D2D),
      fontSize: expanded ? 13.8 : 13.2,
      height: lineHeight,
    );
    if (itemMatch == null) {
      return LatexTextRenderer(
        _toPreviewMathMarkup(normalized, forceMathTokenWrap: true),
        softWrap: true,
        enableDisplayMath: true,
        inlineMathScale: _previewMathScale,
        fractionInlineMathScale: _previewFractionMathScale,
        displayMathScale: _previewMathScale,
        blockVerticalPadding: lineHeight >= 1.9 ? 1.2 : 0.7,
        style: style,
      );
    }
    final rawLabel = (itemMatch.group(1) ?? '').trim();
    final content = (itemMatch.group(2) ?? '').trim();
    final labelText =
        RegExp(r'^[①②③④⑤⑥⑦⑧⑨⑩]$').hasMatch(rawLabel) ? rawLabel : '$rawLabel.';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: expanded ? 24 : 22,
          child: Text(
            labelText,
            style: style.copyWith(fontWeight: FontWeight.w500),
          ),
        ),
        const SizedBox(width: 2),
        Expanded(
          child: LatexTextRenderer(
            _toPreviewMathMarkup(content, forceMathTokenWrap: true),
            softWrap: true,
            enableDisplayMath: true,
            inlineMathScale: _previewMathScale,
            fractionInlineMathScale: _previewFractionMathScale,
            displayMathScale: _previewMathScale,
            blockVerticalPadding:
                _denseMathLineHeight(content, normal: 1.76) >= 1.9 ? 1.2 : 0.7,
            style: TextStyle(
              color: style.color,
              fontSize: style.fontSize,
              height: _denseMathLineHeight(content, normal: 1.76),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildViewBlockPanel(
    List<String> lines, {
    bool expanded = false,
  }) {
    final items =
        lines.where((line) => line.trim().isNotEmpty).toList(growable: false);
    final contentLines =
        items.where((line) => line != '<보기>').toList(growable: false);
    const borderColor = Color(0xFF3F3F3F);
    const panelBgColor = Color(0xFFFCFCFC);
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            decoration: BoxDecoration(
              border: Border.all(color: borderColor, width: 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line in contentLines) ...[
                  _buildViewBlockContentLine(line, expanded: expanded),
                  if (line != contentLines.last)
                    SizedBox(height: expanded ? 12 : 10),
                ],
              ],
            ),
          ),
          Positioned(
            top: -11,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                color: panelBgColor,
                padding: EdgeInsets.zero,
                child: const Text(
                  '<보 기>',
                  style: TextStyle(
                    color: Color(0xFF232323),
                    fontSize: 13.6,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static final _boxMarkerStartRegex = RegExp(r'\[박스시작\]');
  static final _boxMarkerEndRegex = RegExp(r'\[박스끝\]');
  static final _paragraphMarkerRegex = RegExp(r'\[문단\]');

  List<Widget> _buildStemPreviewBlocks(
    ProblemBankQuestion q,
    String stemPreview, {
    bool expanded = false,
  }) {
    final out = <Widget>[];
    final normalized = _normalizePreviewMultiline(stemPreview);
    if (normalized.isEmpty) return out;
    final assets = _orderedFigureAssetsOf(q);

    // [박스시작]/[박스끝] 마커가 있으면 마커 기반 렌더링
    if (_boxMarkerStartRegex.hasMatch(normalized)) {
      return _buildStemBlocksFromMarkers(q, normalized, assets,
          expanded: expanded);
    }

    // fallback: 기존 _boxedStemGroups 휴리스틱
    final boxedGroups = _boxedStemGroups(stemPreview);
    if (boxedGroups.isNotEmpty) {
      final firstGroup = boxedGroups.first;
      final firstJoined = firstGroup.join('\n');
      final beforeText = normalized.split(firstGroup.first).first.trim();
      if (beforeText.isNotEmpty) {
        out.add(_buildStemTextPreviewLine(beforeText));
      }
      final boxChildren = <Widget>[];
      int boxedAssetCursor = 0;
      for (final line in firstGroup) {
        final figMatches =
            _figureMarkerRegex.allMatches(line).toList(growable: false);
        if (figMatches.isEmpty) {
          if (boxChildren.isNotEmpty) {
            boxChildren.add(const SizedBox(height: 4));
          }
          boxChildren.add(_buildStemTextPreviewLine(
            line,
            fontSize: expanded ? 13.5 : 13.1,
            normalHeight: 1.74,
          ));
        } else {
          int lCursor = 0;
          for (final fm in figMatches) {
            final beforeFig = line
                .substring(lCursor, fm.start)
                .replaceAll(_figureMarkerRegex, '')
                .trim();
            if (beforeFig.isNotEmpty) {
              if (boxChildren.isNotEmpty) {
                boxChildren.add(const SizedBox(height: 4));
              }
              boxChildren.add(_buildStemTextPreviewLine(
                beforeFig,
                fontSize: expanded ? 13.5 : 13.1,
                normalHeight: 1.74,
              ));
            }
            if (boxedAssetCursor < assets.length) {
              boxChildren.add(_buildInlineFigureInStem(q,
                  asset: assets[boxedAssetCursor], expanded: expanded));
              boxedAssetCursor += 1;
            }
            lCursor = fm.end;
          }
          final afterFig =
              line.substring(lCursor).replaceAll(_figureMarkerRegex, '').trim();
          if (afterFig.isNotEmpty) {
            if (boxChildren.isNotEmpty) {
              boxChildren.add(const SizedBox(height: 4));
            }
            boxChildren.add(_buildStemTextPreviewLine(
              afterFig,
              fontSize: expanded ? 13.5 : 13.1,
              normalHeight: 1.74,
            ));
          }
        }
      }
      if (boxChildren.isNotEmpty) {
        out.add(_buildBoxedStemContainer(children: boxChildren));
      }
      final afterSource = stemPreview.replaceFirst(firstJoined, '').trim();
      final afterText = _normalizePreviewMultiline(afterSource);
      if (afterText.isNotEmpty) {
        final afterFigureMatches =
            _figureMarkerRegex.allMatches(afterText).toList(growable: false);
        if (afterFigureMatches.isEmpty) {
          out.add(_buildStemTextPreviewLine(afterText));
        } else {
          int afterCursor = 0;
          for (final match in afterFigureMatches) {
            final beforeFig = _normalizePreviewLine(
                afterText.substring(afterCursor, match.start));
            if (beforeFig.isNotEmpty) {
              out.add(_buildStemTextPreviewLine(beforeFig));
            }
            if (boxedAssetCursor < assets.length) {
              out.add(_buildInlineFigureInStem(q,
                  asset: assets[boxedAssetCursor], expanded: expanded));
              boxedAssetCursor += 1;
            }
            afterCursor = match.end;
          }
          final afterTail =
              _normalizePreviewLine(afterText.substring(afterCursor));
          if (afterTail.isNotEmpty) {
            out.add(_buildStemTextPreviewLine(afterTail));
          }
        }
      }
      while (boxedAssetCursor < assets.length) {
        out.add(_buildInlineFigureInStem(q,
            asset: assets[boxedAssetCursor], expanded: expanded));
        boxedAssetCursor += 1;
      }
      if (assets.isEmpty && q.figureRefs.isNotEmpty) {
        out.add(_buildInlineFigureInStem(q, expanded: expanded));
      }
      return out;
    }

    // 마커도 박스 휴리스틱도 없는 일반 stem
    return _buildStemBlocksPlain(q, normalized, assets, expanded: expanded);
  }

  /// [박스시작]/[박스끝] 마커 기반 stem 렌더링
  List<Widget> _buildStemBlocksFromMarkers(
    ProblemBankQuestion q,
    String normalized,
    List<Map<String, dynamic>> assets, {
    bool expanded = false,
  }) {
    final out = <Widget>[];
    int assetCursor = 0;

    // [문단] 마커를 줄바꿈으로 치환하고 연속 줄바꿈 정리
    final cleaned = normalized
        .replaceAll(_paragraphMarkerRegex, '\n')
        .replaceAll(RegExp(r'\n{2,}'), '\n')
        .trim();

    final parts = cleaned.split(_boxMarkerStartRegex);
    for (int pi = 0; pi < parts.length; pi += 1) {
      final part = parts[pi];
      if (part.isEmpty) continue;

      final endSplit = part.split(_boxMarkerEndRegex);
      if (endSplit.length >= 2) {
        // endSplit[0] = 박스 안 내용, endSplit[1..] = 박스 뒤 내용
        final boxContent = endSplit[0].trim();
        if (boxContent.isNotEmpty) {
          final boxChildren = <Widget>[];
          final boxLines = boxContent
              .split('\n')
              .map((l) => l.trim())
              .where((l) => l.isNotEmpty)
              .toList(growable: false);
          for (final line in boxLines) {
            final figMatches =
                _figureMarkerRegex.allMatches(line).toList(growable: false);
            if (figMatches.isEmpty) {
              if (boxChildren.isNotEmpty) {
                boxChildren.add(const SizedBox(height: 4));
              }
              boxChildren.add(_buildStemTextPreviewLine(
                line,
                fontSize: expanded ? 13.5 : 13.1,
                normalHeight: 1.74,
              ));
            } else {
              int lCursor = 0;
              for (final fm in figMatches) {
                final beforeFig = line
                    .substring(lCursor, fm.start)
                    .replaceAll(_figureMarkerRegex, '')
                    .trim();
                if (beforeFig.isNotEmpty) {
                  if (boxChildren.isNotEmpty) {
                    boxChildren.add(const SizedBox(height: 4));
                  }
                  boxChildren.add(_buildStemTextPreviewLine(
                    beforeFig,
                    fontSize: expanded ? 13.5 : 13.1,
                    normalHeight: 1.74,
                  ));
                }
                if (assetCursor < assets.length) {
                  boxChildren.add(_buildInlineFigureInStem(q,
                      asset: assets[assetCursor], expanded: expanded));
                  assetCursor += 1;
                }
                lCursor = fm.end;
              }
              final afterFig = line
                  .substring(lCursor)
                  .replaceAll(_figureMarkerRegex, '')
                  .trim();
              if (afterFig.isNotEmpty) {
                if (boxChildren.isNotEmpty) {
                  boxChildren.add(const SizedBox(height: 4));
                }
                boxChildren.add(_buildStemTextPreviewLine(
                  afterFig,
                  fontSize: expanded ? 13.5 : 13.1,
                  normalHeight: 1.74,
                ));
              }
            }
          }
          if (boxChildren.isNotEmpty) {
            out.add(_buildBoxedStemContainer(children: boxChildren));
          }
        }
        // 박스 뒤 내용
        final afterBox = endSplit.sublist(1).join('').trim();
        if (afterBox.isNotEmpty) {
          assetCursor = _appendPlainStemSegment(
              q, afterBox, assets, assetCursor, out,
              expanded: expanded);
        }
      } else {
        // [박스시작] 앞의 일반 텍스트 (첫 번째 part)
        final text = part.trim();
        if (text.isNotEmpty) {
          assetCursor = _appendPlainStemSegment(
              q, text, assets, assetCursor, out,
              expanded: expanded);
        }
      }
    }

    while (assetCursor < assets.length) {
      out.add(_buildInlineFigureInStem(q,
          asset: assets[assetCursor], expanded: expanded));
      assetCursor += 1;
    }
    if (assets.isEmpty && q.figureRefs.isNotEmpty) {
      out.add(_buildInlineFigureInStem(q, expanded: expanded));
    }
    return out;
  }

  /// 마커/박스 없는 일반 stem 렌더링
  List<Widget> _buildStemBlocksPlain(
    ProblemBankQuestion q,
    String normalized,
    List<Map<String, dynamic>> assets, {
    bool expanded = false,
  }) {
    final out = <Widget>[];
    // [문단] 마커를 줄바꿈으로 치환하고 연속 줄바꿈 정리
    final cleaned = normalized
        .replaceAll(_paragraphMarkerRegex, '\n')
        .replaceAll(RegExp(r'\n{2,}'), '\n')
        .trim();
    final matches =
        _figureMarkerRegex.allMatches(cleaned).toList(growable: false);
    if (matches.isEmpty) {
      out.add(_buildStemTextPreviewLine(cleaned));
      if (assets.isNotEmpty) {
        final maxFallback = expanded ? assets.length : 1;
        for (int i = 0; i < maxFallback && i < assets.length; i += 1) {
          out.add(_buildInlineFigureInStem(q,
              asset: assets[i], expanded: expanded));
        }
      } else if (q.figureRefs.isNotEmpty) {
        out.add(_buildInlineFigureInStem(q, expanded: expanded));
      }
      return out;
    }
    int cursor = 0;
    int assetCursor = 0;
    for (final match in matches) {
      final before =
          _normalizePreviewMultiline(cleaned.substring(cursor, match.start));
      if (before.isNotEmpty) {
        out.add(_buildStemTextPreviewLine(before));
      }
      if (assetCursor < assets.length) {
        out.add(
          _buildInlineFigureInStem(
            q,
            asset: assets[assetCursor],
            expanded: expanded,
          ),
        );
        assetCursor += 1;
      } else {
        out.add(_buildInlineFigureInStem(q, expanded: expanded));
      }
      cursor = match.end;
    }
    final tail = _normalizePreviewMultiline(cleaned.substring(cursor));
    if (tail.isNotEmpty) {
      out.add(_buildStemTextPreviewLine(tail));
    }
    while (assetCursor < assets.length) {
      out.add(
        _buildInlineFigureInStem(
          q,
          asset: assets[assetCursor],
          expanded: expanded,
        ),
      );
      assetCursor += 1;
    }
    if (assets.isEmpty && q.figureRefs.isNotEmpty) {
      out.add(_buildInlineFigureInStem(q, expanded: expanded));
    }
    return out;
  }

  /// 일반 텍스트 세그먼트를 파싱하여 텍스트/그림 위젯을 out에 추가하고 assetCursor를 반환
  int _appendPlainStemSegment(
    ProblemBankQuestion q,
    String text,
    List<Map<String, dynamic>> assets,
    int assetCursor,
    List<Widget> out, {
    bool expanded = false,
  }) {
    final figMatches =
        _figureMarkerRegex.allMatches(text).toList(growable: false);
    if (figMatches.isEmpty) {
      out.add(_buildStemTextPreviewLine(text));
      return assetCursor;
    }
    int cursor = 0;
    for (final match in figMatches) {
      final before = _normalizePreviewLine(text.substring(cursor, match.start));
      if (before.isNotEmpty) {
        out.add(_buildStemTextPreviewLine(before));
      }
      if (assetCursor < assets.length) {
        out.add(_buildInlineFigureInStem(q,
            asset: assets[assetCursor], expanded: expanded));
        assetCursor += 1;
      }
      cursor = match.end;
    }
    final tail = _normalizePreviewLine(text.substring(cursor));
    if (tail.isNotEmpty) {
      out.add(_buildStemTextPreviewLine(tail));
    }
    return assetCursor;
  }

  Widget _buildChoicePreviewLine(ProblemBankQuestion q, ProblemBankChoice c) {
    final rendered = _normalizePreviewLine(q.renderChoiceText(c));
    final lineHeight = _choicePreviewLineHeight(rendered);
    final previewText = _toPreviewMathMarkup(rendered,
        forceMathTokenWrap: true, compactFractions: true);
    const contentFontSize = 13.4;
    const labelFontSize = contentFontSize + 1.6;
    final textStyle = TextStyle(
      color: const Color(0xFF232323),
      fontSize: contentFontSize,
      height: lineHeight,
    );
    return Padding(
      padding: EdgeInsets.only(
        bottom: lineHeight >= 1.80
            ? 4.2
            : lineHeight >= 1.70
                ? 3.4
                : 2.0,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            c.label,
            style: const TextStyle(
              color: Color(0xFF232323),
              fontSize: labelFontSize,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: LatexTextRenderer(
              previewText,
              softWrap: true,
              enableDisplayMath: true,
              inlineMathScale: _previewMathScale,
              fractionInlineMathScale: _previewFractionMathScale,
              displayMathScale: _previewMathScale,
              blockVerticalPadding: lineHeight >= 1.80
                  ? 1.6
                  : lineHeight >= 1.70
                      ? 1.2
                      : 0.8,
              style: textStyle,
            ),
          ),
        ],
      ),
    );
  }

  /// LaTeX 소스에서 렌더링 후 시각적 길이를 추정
  int _estimateVisualLength(String text) {
    var s = text;
    // \frac{a}{b} → "a/b" (3~5글자 정도로 축소)
    s = s.replaceAllMapped(
      RegExp(r'\\(?:d?frac)\{([^{}]*)\}\{([^{}]*)\}'),
      (m) => '${m.group(1)}/${m.group(2)}',
    );
    // {a} \over {b} → "a/b"
    s = s.replaceAllMapped(
      RegExp(r'\{([^{}]*)\}\s*\\over\s*\{([^{}]*)\}'),
      (m) => '${m.group(1)}/${m.group(2)}',
    );
    // \mathrm{-5} → "-5"
    s = s.replaceAllMapped(
      RegExp(r'\\mathrm\{([^{}]*)\}'),
      (m) => m.group(1) ?? '',
    );
    // 나머지 LaTeX 명령어 제거
    s = s.replaceAll(RegExp(r'\\[a-zA-Z]+'), ' ');
    s = s.replaceAll(RegExp(r'[{}]'), '');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s.length;
  }

  String _choiceLayoutMode(
    ProblemBankQuestion q,
    List<ProblemBankChoice> choices,
  ) {
    if (choices.length != 5) return 'stacked';
    int totalVisual = 0;
    int maxVisual = 0;
    bool hasNestedFraction = false;
    bool hasFraction = false;
    bool hasLongMath = false;
    for (final choice in choices) {
      final text = _normalizePreviewLine(q.renderChoiceText(choice));
      final visual = _estimateVisualLength(text);
      totalVisual += visual;
      if (visual > maxVisual) {
        maxVisual = visual;
      }
      final latex = _sanitizeLatexForMathTex(text);
      if (_containsNestedFractionExpression(latex)) {
        hasNestedFraction = true;
      } else if (_containsFractionExpression(latex)) {
        hasFraction = true;
      }
      if (RegExp(r'\\(sqrt|sum|int|overline)').hasMatch(latex)) {
        hasLongMath = true;
      }
    }
    if (hasNestedFraction || hasLongMath || maxVisual >= 20) {
      return 'stacked';
    }
    if (hasFraction) {
      if (maxVisual <= 12 && totalVisual <= 50) {
        return 'split_3_2';
      }
      if (maxVisual >= 16 || totalVisual >= 70) {
        return 'stacked';
      }
      return 'split_3_2';
    }
    if (maxVisual <= 9 && totalVisual <= 42) {
      return 'single';
    }
    return 'split_3_2';
  }

  Widget _buildChoiceInlineCell(
    ProblemBankQuestion q,
    ProblemBankChoice c, {
    bool expanded = false,
  }) {
    final rendered = _normalizePreviewLine(q.renderChoiceText(c));
    final lineHeight = _choicePreviewLineHeight(rendered);
    final contentFontSize = expanded ? 13.6 : 13.4;
    final labelFontSize = contentFontSize + 1.6;
    final textStyle = TextStyle(
      color: const Color(0xFF232323),
      fontSize: contentFontSize,
      height: lineHeight,
    );
    return ClipRect(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            c.label,
            style: TextStyle(
              color: const Color(0xFF232323),
              fontSize: labelFontSize,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 4),
          Flexible(
            child: LatexTextRenderer(
              _toPreviewMathMarkup(rendered,
                  forceMathTokenWrap: true, compactFractions: true),
              softWrap: true,
              enableDisplayMath: true,
              inlineMathScale: _previewMathScale,
              fractionInlineMathScale: _previewFractionMathScale,
              displayMathScale: _previewMathScale,
              blockVerticalPadding: lineHeight >= 1.80
                  ? 1.2
                  : lineHeight >= 1.70
                      ? 0.9
                      : 0.5,
              style: textStyle,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChoiceHorizontalRow(
    ProblemBankQuestion q,
    List<ProblemBankChoice> rowChoices, {
    required int columns,
    bool expanded = false,
  }) {
    final cells = <Widget>[];
    for (int i = 0; i < columns; i += 1) {
      if (i < rowChoices.length) {
        cells.add(
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: expanded ? 1 : 0.6),
              child: _buildChoiceInlineCell(
                q,
                rowChoices[i],
                expanded: expanded,
              ),
            ),
          ),
        );
      } else {
        cells.add(const Expanded(child: SizedBox.shrink()));
      }
      if (i < columns - 1) {
        cells.add(SizedBox(width: expanded ? 10 : 8));
      }
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: cells,
    );
  }

  List<Widget> _buildChoicePreviewBlocks(
    ProblemBankQuestion q, {
    bool expanded = false,
  }) {
    final choices = q.choices.take(expanded ? 10 : 5).toList(growable: false);
    if (choices.isEmpty) return const <Widget>[];
    final mode = _choiceLayoutMode(q, choices);
    if (mode == 'single') {
      return <Widget>[
        _buildChoiceHorizontalRow(q, choices, columns: 5, expanded: expanded)
      ];
    }
    if (mode == 'split_3_2') {
      return <Widget>[
        _buildChoiceHorizontalRow(
          q,
          choices.take(3).toList(growable: false),
          columns: 3,
          expanded: expanded,
        ),
        SizedBox(height: expanded ? 7 : 6),
        _buildChoiceHorizontalRow(
          q,
          choices.skip(3).toList(growable: false),
          columns: 3,
          expanded: expanded,
        ),
      ];
    }
    return <Widget>[
      for (final choice in choices) _buildChoicePreviewLine(q, choice),
    ];
  }

  /// 구조 마커를 보존한 stem (박스/문단 렌더링용)
  String _stemPreviewWithMarkers(ProblemBankQuestion q) {
    var out = _normalizePreviewMultiline(q.renderedStem);
    if (out.isEmpty) return '';
    out = out.replaceFirst(RegExp(r'^(\s*\[(문단|박스끝)\]\s*)+'), '');
    out = out.replaceFirst(RegExp(r'(\s*\[(문단|박스시작)\]\s*)+$'), '');
    final qn = q.questionNumber.trim();
    if (qn.isNotEmpty) {
      final escaped = RegExp.escape(qn);
      final lines = out.split('\n');
      if (lines.isNotEmpty) {
        lines[0] = lines[0]
            .replaceFirst(RegExp('^\\s*$escaped\\s*[\\.)．]\\s*'), '')
            .replaceFirst(RegExp('^\\s*$escaped\\s+(?=[^\\s])'), '');
        out = lines
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty)
            .join('\n');
      }
    }
    final markerNormalized = out.replaceAll(RegExp(r'<\s*보\s*기>'), '<보기>');
    final lastMarker = markerNormalized.lastIndexOf('<보기>');
    if (lastMarker > 0 &&
        RegExp(r'[ㄱ-ㅎ]\.').hasMatch(markerNormalized.substring(lastMarker))) {
      return _normalizePreviewMultiline(
          markerNormalized.substring(0, lastMarker));
    }
    return _normalizePreviewMultiline(out);
  }

  Widget _buildPdfPreviewThumbnail(ProblemBankQuestion q,
      {bool expanded = false}) {
    final stemPreview = _stemPreviewWithMarkers(q);
    final viewBlockLines = _viewBlockPreviewLines(q, max: expanded ? 18 : 6);
    final stemBlocks =
        _buildStemPreviewBlocks(q, stemPreview, expanded: expanded);
    return Container(
      height: expanded ? null : 260,
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF0E1518),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _border),
      ),
      padding: const EdgeInsets.all(8.5),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFFCFCFC),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFFD5D5D5)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x1A000000),
              blurRadius: 3,
              offset: Offset(0, 1),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
        child: SingleChildScrollView(
          physics: const ClampingScrollPhysics(),
          child: DefaultTextStyle(
            style: const TextStyle(
              color: Color(0xFF232323),
              fontSize: 13.4,
              height: 1.46,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ...stemBlocks,
                if (viewBlockLines.isNotEmpty) ...[
                  _buildViewBlockPanel(
                    viewBlockLines
                        .take(expanded ? 18 : 6)
                        .toList(growable: false),
                    expanded: expanded,
                  ),
                ],
                if (q.choices.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  ..._buildChoicePreviewBlocks(q, expanded: expanded),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  double _previewDialogWidth(ProblemBankQuestion q, Size screenSize) {
    final totalChars = _normalizePreviewLine(q.renderedStem).length +
        q.choices.fold<int>(
            0,
            (sum, c) =>
                sum + _normalizePreviewLine(q.renderChoiceText(c)).length);
    final preferred = totalChars >= 460
        ? 1080.0
        : totalChars >= 320
            ? 980.0
            : totalChars >= 180
                ? 900.0
                : 820.0;
    return preferred.clamp(620.0, screenSize.width - 48).toDouble();
  }

  double _previewDialogHeight(ProblemBankQuestion q, Size screenSize) {
    final totalChars = _normalizePreviewLine(q.renderedStem).length +
        q.choices.fold<int>(
            0,
            (sum, c) =>
                sum + _normalizePreviewLine(q.renderChoiceText(c)).length);
    final preferred =
        (420 + totalChars * 0.42).clamp(420.0, screenSize.height * 0.9);
    return preferred.toDouble();
  }

  Future<void> _openPreviewZoomDialog(ProblemBankQuestion q) async {
    if (!mounted) return;
    final screen = MediaQuery.sizeOf(context);
    final dialogWidth = _previewDialogWidth(q, screen);
    final dialogHeight = _previewDialogHeight(q, screen);
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return Dialog(
          backgroundColor: _panel,
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: dialogWidth,
              maxHeight: dialogHeight,
              minWidth: 560,
              minHeight: 380,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        '${q.questionNumber}번 확대 미리보기',
                        style: const TextStyle(
                          color: _text,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: '닫기',
                        onPressed: () => Navigator.of(ctx).pop(),
                        icon: const Icon(Icons.close, color: _textSub),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildPdfPreviewThumbnail(q, expanded: true),
                          const SizedBox(height: 10),
                          _buildAnswerPreviewThumbnail(q, expanded: true),
                          if (q.figureRefs.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            _buildFigurePreviewThumbnail(q, expanded: true),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _openFigurePreviewDialog(ProblemBankQuestion q) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return Dialog(
          backgroundColor: _panel,
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720, maxHeight: 600),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        '${q.questionNumber}번 AI 그림 미리보기',
                        style: const TextStyle(
                          color: _text,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: '닫기',
                        onPressed: () => Navigator.of(ctx).pop(),
                        icon: const Icon(Icons.close, color: _textSub),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: SingleChildScrollView(
                      child: _buildFigurePreviewThumbnail(q, expanded: true),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _openAnswerReviewDialog(ProblemBankQuestion question) async {
    final answerCtrl =
        TextEditingController(text: _answerTextForPreview(question));
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: _panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: _border),
          ),
          title: Text(
            '${question.questionNumber}번 정답 검수',
            style: const TextStyle(color: _text, fontSize: 16),
          ),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '정답 추출값',
                  style: TextStyle(color: _textSub, fontSize: 12),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: answerCtrl,
                  maxLines: 2,
                  style: const TextStyle(color: _text, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: '예: ③ 또는 2',
                    hintStyle: const TextStyle(color: _textSub, fontSize: 12),
                    filled: true,
                    fillColor: _field,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: _border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: _border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: _accent),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '비워두고 저장하면 정답 추출값을 비웁니다.',
                  style: TextStyle(color: _textSub, fontSize: 11),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('취소'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _accent),
              onPressed: () async {
                try {
                  final answer = answerCtrl.text.trim();
                  final updatedMeta = Map<String, dynamic>.from(question.meta);
                  if (answer.isEmpty) {
                    updatedMeta.remove('answer_key');
                  } else {
                    updatedMeta['answer_key'] = answer;
                  }
                  await _service.updateQuestionReview(
                    questionId: question.id,
                    isChecked: question.isChecked,
                    meta: updatedMeta,
                  );
                  if (!mounted) return;
                  setState(() {
                    _questions = _questions
                        .map(
                          (q) => q.id == question.id
                              ? q.copyWith(meta: updatedMeta)
                              : q,
                        )
                        .toList(growable: false);
                  });
                  if (context.mounted) Navigator.of(context).pop(true);
                } catch (e) {
                  _showSnack('정답 저장 실패: $e', error: true);
                }
              },
              child: const Text('저장'),
            ),
          ],
        );
      },
    );
    if (saved == true) {
      await _reloadQuestions();
      _showSnack('정답 검수 내용이 저장되었습니다.');
    }
  }

  Widget _buildQuestionGridCard(ProblemBankQuestion q) {
    final confidenceColor = q.confidence >= 0.9
        ? const Color(0xFF41B883)
        : (q.confidence >= 0.8
            ? const Color(0xFFE3B341)
            : const Color(0xFFDE6A73));
    final typeText = q.questionType.trim().isEmpty ? '미분류' : q.questionType;
    final isViewBlock = _isViewBlockQuestion(q);
    final latestFigureAsset = _latestFigureAssetOf(q);
    final figureApproved = _isFigureAssetApproved(latestFigureAsset);
    final figureGenerating = _figureGenerating.contains(q.id);
    final scoreDraft = _scoreDraftFor(q);
    final isScoreSaving = _scoreSaving.contains(q.id);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _field,
        borderRadius: BorderRadius.circular(10),
        border:
            Border.all(color: _isLowConfidence(q) ? confidenceColor : _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Checkbox(
                value: q.isChecked,
                activeColor: _accent,
                visualDensity:
                    const VisualDensity(horizontal: -4, vertical: -4),
                onChanged: (v) {
                  if (v == null) return;
                  unawaited(_toggleChecked(q, v));
                },
              ),
              Text(
                '${q.questionNumber}번',
                style: const TextStyle(
                  color: _text,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: _panel,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _border),
                ),
                child: Text(
                  typeText,
                  style: const TextStyle(color: _textSub, fontSize: 11),
                ),
              ),
              if (isViewBlock) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF15304A),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF356A92)),
                  ),
                  child: const Text(
                    '<보기>형',
                    style: TextStyle(
                      color: Color(0xFF9CC5E8),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: confidenceColor.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: confidenceColor),
                ),
                child: Text(
                  '${(q.confidence * 100).round()}%',
                  style: TextStyle(
                    color: confidenceColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            'p.${q.sourcePage}'
            ' · 보기 ${q.choices.length}개'
            ' · 수식 ${q.equations.length}개'
            '${isViewBlock ? ' · 보기형' : ''}'
            '${q.figureRefs.isNotEmpty ? ' · 그림 포함' : ''}',
            style: const TextStyle(color: _textSub, fontSize: 11),
          ),
          const SizedBox(height: 7),
          Row(
            children: [
              const Text(
                '배점',
                style: TextStyle(
                  color: _textSub,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 72,
                height: 30,
                child: TextFormField(
                  key: ValueKey('score-${q.id}-${q.meta['score_point'] ?? ''}'),
                  initialValue: scoreDraft,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  onChanged: (value) {
                    _scoreDrafts[q.id] = value;
                  },
                  onFieldSubmitted: (_) => unawaited(_saveScoreDraft(q)),
                  style: const TextStyle(color: _text, fontSize: 12.6),
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                    filled: true,
                    fillColor: const Color(0xFF11191D),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: const BorderSide(color: _border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: const BorderSide(color: _accent),
                    ),
                    hintText: '점수',
                    hintStyle: const TextStyle(color: _textSub, fontSize: 11),
                  ),
                ),
              ),
              const SizedBox(width: 5),
              const Text(
                '점',
                style: TextStyle(color: _textSub, fontSize: 11.5),
              ),
              const SizedBox(width: 2),
              IconButton(
                tooltip: '배점 저장',
                iconSize: 17,
                visualDensity:
                    const VisualDensity(horizontal: -4, vertical: -4),
                onPressed:
                    isScoreSaving ? null : () => unawaited(_saveScoreDraft(q)),
                icon: isScoreSaving
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.7,
                          color: _textSub,
                        ),
                      )
                    : const Icon(Icons.save_outlined, color: _textSub),
              ),
              const Spacer(),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '문제 미리보기',
            style: TextStyle(color: _textSub, fontSize: 11),
          ),
          const SizedBox(height: 4),
          InkWell(
            onTap: () => unawaited(_openPreviewZoomDialog(q)),
            borderRadius: BorderRadius.circular(8),
            child: _buildPdfPreviewThumbnail(q),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text(
                '정답 미리보기',
                style: TextStyle(color: _textSub, fontSize: 11),
              ),
              const Spacer(),
              IconButton(
                tooltip: '정답 검수 편집',
                iconSize: 18,
                visualDensity:
                    const VisualDensity(horizontal: -4, vertical: -4),
                onPressed: () => unawaited(_openAnswerReviewDialog(q)),
                icon: const Icon(
                  Icons.playlist_add_check_circle_outlined,
                  color: _textSub,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          _buildAnswerPreviewThumbnail(q),
          if (q.figureRefs.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const Text(
                  'AI 그림',
                  style: TextStyle(color: _textSub, fontSize: 11),
                ),
                const SizedBox(width: 6),
                if (latestFigureAsset != null) ...[
                  InkWell(
                    onTap: () => unawaited(_openFigurePreviewDialog(q)),
                    borderRadius: BorderRadius.circular(4),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFF15304A),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: const Color(0xFF356A92)),
                      ),
                      child: const Text(
                        '미리보기',
                        style: TextStyle(
                          color: Color(0xFF9CC5E8),
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Text('승인',
                      style: TextStyle(color: _textSub, fontSize: 10.5)),
                  SizedBox(
                    height: 24,
                    child: Switch(
                      value: figureApproved,
                      activeThumbColor: _accent,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onChanged: (v) => unawaited(
                        _toggleFigureAssetApproval(q, latestFigureAsset, v),
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                IconButton(
                  tooltip: 'AI 그림 생성',
                  iconSize: 17,
                  visualDensity:
                      const VisualDensity(horizontal: -4, vertical: -4),
                  onPressed: figureGenerating
                      ? null
                      : () => unawaited(_requestFigureGeneration(q)),
                  icon: figureGenerating
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.6,
                            color: _textSub,
                          ),
                        )
                      : const Icon(
                          Icons.auto_awesome_outlined,
                          color: _textSub,
                          size: 17,
                        ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              IconButton(
                tooltip: '검수 편집',
                iconSize: 18,
                onPressed: () => unawaited(_openReviewDialog(q)),
                icon: const Icon(
                  Icons.edit_note,
                  color: _textSub,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildQuestionTable() {
    return Container(
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionTitle(
            '2) 추출 문항 검수',
            subtitle: '그리드 카드에서 PDF 배치 미리보기를 확인하며 검수하세요.',
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Text(
                '총 ${_questions.length}문항 · 선택 $_checkedCount문항 · 저신뢰 $_lowConfidenceCount문항',
                style: const TextStyle(
                  color: _textSub,
                  fontSize: 12,
                ),
              ),
              const Spacer(),
              OutlinedButton(
                onPressed: _questions.isEmpty
                    ? null
                    : () => unawaited(_setAllChecked(true)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _accent,
                  side: const BorderSide(color: _accent),
                ),
                child: const Text('전체 선택'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _questions.isEmpty
                    ? null
                    : () => unawaited(_setAllChecked(false)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _textSub,
                  side: const BorderSide(color: _border),
                ),
                child: const Text('선택 해제'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _questions.isEmpty
                    ? null
                    : () {
                        setState(() {
                          _showLowConfidenceOnly = !_showLowConfidenceOnly;
                        });
                      },
                style: OutlinedButton.styleFrom(
                  foregroundColor: _showLowConfidenceOnly ? _accent : _textSub,
                  side: BorderSide(
                    color: _showLowConfidenceOnly ? _accent : _border,
                  ),
                ),
                child: Text(
                  _showLowConfidenceOnly ? '전체 보기' : '저신뢰만',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: _visibleQuestions.isEmpty
                ? const Center(
                    child: Text(
                      '표시할 문항이 없습니다.',
                      style: TextStyle(color: _textSub),
                    ),
                  )
                : GridView.builder(
                    itemCount: _visibleQuestions.length,
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 420,
                      mainAxisExtent: 790,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                    ),
                    itemBuilder: (context, index) {
                      final q = _visibleQuestions[index];
                      return _buildQuestionGridCard(q);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool step1Done = _hasExtracted &&
        _activeDocument != null &&
        !_isUploading &&
        !_isExtracting;
    final bool step2Done = _checkedCount > 0;
    final bool step3Active = _isExporting;

    final canUpload = !_bootstrapLoading &&
        !_schemaMissing &&
        !_academyMissing &&
        _academyId != null &&
        _academyId!.isNotEmpty;
    final canReset = canUpload &&
        !_isResetting &&
        !_isUploading &&
        !_isExtracting &&
        !_isExporting;

    return Container(
      color: _bg,
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
      child: _bootstrapLoading
          ? const Center(
              child: CircularProgressIndicator(
                color: _accent,
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '문제은행',
                            style: TextStyle(
                              color: _text,
                              fontSize: 24,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          SizedBox(height: 8),
                          Text(
                            'HWPX(한글+수식) 추출, 검수, 양식 PDF 생성을 하나의 흐름으로 관리합니다.',
                            style: TextStyle(color: _textSub, fontSize: 14),
                          ),
                        ],
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: (_isResetting ||
                              _isUploading ||
                              _isExtracting ||
                              !canUpload)
                          ? null
                          : _pickAndUploadHwpx,
                      style: FilledButton.styleFrom(
                        backgroundColor: _accent,
                        foregroundColor: Colors.white,
                      ),
                      icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                      label: const Text('HWPX 업로드'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: _isResetting
                          ? null
                          : () => unawaited(_refreshDocuments()),
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('새로고침'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: canReset
                          ? () => unawaited(_resetPipelineData())
                          : null,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFDE6A73),
                        side: const BorderSide(color: Color(0xFFDE6A73)),
                      ),
                      icon: _isResetting
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Color(0xFFDE6A73),
                              ),
                            )
                          : const Icon(Icons.delete_sweep_outlined, size: 16),
                      label: Text(_isResetting ? '리셋 중...' : '작업 리셋'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _buildStepChip(
                      index: 1,
                      title: '업로드/정규화',
                      active: _isUploading || _isExtracting,
                      done: step1Done,
                    ),
                    _buildStepChip(
                      index: 2,
                      title: '검수/선택',
                      active: !(_isUploading || _isExtracting) && !step2Done,
                      done: step2Done,
                    ),
                    _buildStepChip(
                      index: 3,
                      title: '양식 PDF 생성',
                      active: step3Active,
                      done: _hasExported && !step3Active,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 380,
                        child: Column(
                          children: [
                            _buildUploadPanel(),
                            const SizedBox(height: 12),
                            _buildTemplatePanel(),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildQuestionTable(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class _PipelineLogEntry {
  const _PipelineLogEntry({
    required this.at,
    required this.stage,
    required this.message,
    required this.isError,
  });

  final DateTime at;
  final String stage;
  final String message;
  final bool isError;
}

class _PasteImportPayload {
  const _PasteImportPayload({
    required this.rawText,
    required this.sourceName,
  });

  final String rawText;
  final String sourceName;
}
