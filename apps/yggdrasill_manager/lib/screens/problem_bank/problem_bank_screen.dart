import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';

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
        exportStatus == 'rendering';
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
      setState(() {
        _activeDocument = summary.document;
        _activeExtractJob = summary.latestExtractJob;
        _activeExportJob = summary.latestExportJob;
        _questions = questions;
        _hasExtracted = questions.isNotEmpty;
        _isExtracting =
            extractStatus == 'queued' || extractStatus == 'extracting';
        _isExporting = exportStatus == 'queued' || exportStatus == 'rendering';
        _hasExported = exportStatus == 'completed';
        _lastExtractStatus = extractStatus.isEmpty ? null : extractStatus;
        _lastExportStatus = exportStatus.isEmpty ? null : exportStatus;
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

  void _ensurePolling() {
    final hasPendingExtract = _activeExtractJob != null &&
        !_activeExtractJob!.isTerminal &&
        (_activeExtractJob!.status == 'queued' ||
            _activeExtractJob!.status == 'extracting');
    final hasPendingExport = _activeExportJob != null &&
        !_activeExportJob!.isTerminal &&
        (_activeExportJob!.status == 'queued' ||
            _activeExportJob!.status == 'rendering');
    if (!hasPendingExtract && !hasPendingExport) {
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
        });
        if (latest.isTerminal) {
          shouldRefreshQuestions = true;
          if (latest.status == 'failed') {
            _showSnack(
              '추출 실패: ${latest.errorMessage.isEmpty ? latest.errorCode : latest.errorMessage}',
              error: true,
            );
          }
          nextStatusText = latest.status == 'review_required'
              ? '저신뢰 문항이 있어 검수가 필요합니다.'
              : '추출이 완료되었습니다.';
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
        _hasExtracted = questions.isNotEmpty;
        _isExtracting = false;
      });
      _appendPipelineLog('review', '문항 목록 갱신: ${questions.length}건');
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
    stemCtrl.dispose();
    noteCtrl.dispose();
    for (final ctrl in equationCtrls) {
      ctrl.dispose();
    }
    if (result == true) {
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

  String _compactPreviewText(String raw, {int maxChars = 90}) {
    final normalized = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) return '-';
    if (normalized.length <= maxChars) return normalized;
    return '${normalized.substring(0, maxChars)}...';
  }

  String _normalizePreviewLine(String raw) {
    return raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String _firstEquationPreview(ProblemBankQuestion question) {
    if (question.equations.isEmpty) return '';
    return question.previewEquation;
  }

  String _normalizeLatexPreview(String raw) {
    String out = raw.replaceAll(RegExp(r'`+'), '');
    out = out
        .replaceAll(RegExp(r'\{rm\{([^}]*)\}\}it', caseSensitive: false),
            r'\\mathrm{$1}')
        .replaceAll(
            RegExp(r'rm\{([^}]*)\}it', caseSensitive: false), r'\\mathrm{$1}')
        .replaceAll(RegExp(r'\bleft\b', caseSensitive: false), r'\left')
        .replaceAll(RegExp(r'\bright\b', caseSensitive: false), r'\right')
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

    final leftCount =
        RegExp(r'\\left(?=[\\\[\]\(\)\{\}\|.])').allMatches(out).length;
    final rightCount =
        RegExp(r'\\right(?=[\\\[\]\(\)\{\}\|.])').allMatches(out).length;
    if (leftCount != rightCount) {
      out = out.replaceAll(r'\left', '').replaceAll(r'\right', '');
    }
    return out.trim();
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
        RegExp(r'(^|[^\\])\d+\s*/\s*\d+').hasMatch(raw);
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
    return RegExp(r'[=^_{}\\]|[\d]|\\times|\\over|\\le|\\ge').hasMatch(input);
  }

  String _toPreviewMathMarkup(String raw) {
    final input = raw.trim();
    if (input.isEmpty) return '';
    final buffer = StringBuffer();
    int lastIndex = 0;
    final nonKoreanSegments = RegExp(r'[^가-힣]+');
    for (final match in nonKoreanSegments.allMatches(input)) {
      if (match.start > lastIndex) {
        buffer.write(input.substring(lastIndex, match.start));
      }
      final segment = input.substring(match.start, match.end);
      final latex = _sanitizeLatexForMathTex(segment);
      final compact = latex.replaceAll(RegExp(r'[\s\.,;:!?()\[\]<>]'), '');
      final hasMathOperator =
          RegExp(r'[=^_{}\\]|[+\-*/<>]|\\times|\\over|\\div|\\le|\\ge')
              .hasMatch(latex);
      final looksJustNumbering =
          RegExp(r'^[①②③④⑤⑥⑦⑧⑨⑩0-9.\-]+$').hasMatch(compact);
      final shouldWrap = compact.isNotEmpty &&
          !looksJustNumbering &&
          _looksLikeMathCandidate(latex) &&
          hasMathOperator &&
          !_isLikelyLatexParseUnsafe(latex);
      if (shouldWrap) {
        buffer.write(r'\(');
        buffer.write(latex);
        buffer.write(r'\)');
      } else {
        if (_looksLikeMathCandidate(latex)) {
          buffer.write(_latexToPlainPreview(latex));
        } else {
          buffer.write(segment);
        }
      }
      lastIndex = match.end;
    }
    if (lastIndex < input.length) {
      buffer.write(input.substring(lastIndex));
    }
    return buffer.toString();
  }

  bool _isViewBlockQuestion(ProblemBankQuestion q) {
    final stem = q.renderedStem;
    if (q.flags.contains('view_block')) return true;
    if (RegExp(r'<\s*보\s*기>').hasMatch(stem)) return true;
    return RegExp(r'(^|\n)\s*[ㄱ-ㅎ]\.').hasMatch(stem);
  }

  List<String> _viewBlockPreviewLines(ProblemBankQuestion q, {int max = 6}) {
    final lines = q.renderedStem
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (lines.isEmpty) return const <String>[];
    final markerIdx =
        lines.indexWhere((line) => RegExp(r'<\s*보\s*기>').hasMatch(line));
    int start = markerIdx >= 0
        ? markerIdx + 1
        : lines.indexWhere((line) => RegExp(r'^[ㄱ-ㅎ]\.').hasMatch(line));
    if (start < 0) return const <String>[];

    final out = <String>[];
    if (markerIdx >= 0) out.add('<보기>');
    for (int i = start; i < lines.length; i += 1) {
      final line = lines[i];
      if (RegExp(r'^[①②③④⑤⑥⑦⑧⑨⑩]').hasMatch(line)) break;
      if (!RegExp(r'^[ㄱ-ㅎ]\.').hasMatch(line) && out.isNotEmpty) continue;
      out.add(line);
      if (out.length >= max + (markerIdx >= 0 ? 1 : 0)) break;
    }
    if (out.length <= (markerIdx >= 0 ? 1 : 0)) {
      final normalized = _normalizePreviewLine(q.renderedStem);
      final markerMatch = RegExp(r'<\s*보\s*기>').firstMatch(normalized);
      if (markerMatch != null) {
        final after = normalized.substring(markerMatch.end).trim();
        final parts = after
            .split(RegExp(r'(?=[ㄱ-ㅎ]\.)'))
            .map((e) => e.trim())
            .where((e) => RegExp(r'^[ㄱ-ㅎ]\.').hasMatch(e))
            .toList(growable: false);
        if (parts.isNotEmpty) {
          if (out.isEmpty) out.add('<보기>');
          for (final p in parts.take(max)) {
            out.add(p);
          }
        }
      }
    }
    return out;
  }

  String _stemHeadlinePreview(ProblemBankQuestion q) {
    final normalized = _normalizePreviewLine(q.renderedStem);
    if (normalized.isEmpty) return '-';
    final markerMatch = RegExp(r'<\s*보\s*기>').firstMatch(normalized);
    if (markerMatch != null && markerMatch.start > 0) {
      return normalized.substring(0, markerMatch.start).trim();
    }
    return normalized;
  }

  Widget _buildChoicePreviewLine(ProblemBankQuestion q, ProblemBankChoice c) {
    const textStyle = TextStyle(
      color: Color(0xFF232323),
      fontSize: 11.2,
      height: 1.44,
    );
    final rendered = _normalizePreviewLine(q.renderChoiceText(c));
    final latexCandidate = _sanitizeLatexForMathTex(rendered);
    final hasFraction = _containsFractionExpression(latexCandidate);
    final isSafeMath = _looksLikeMathCandidate(latexCandidate) &&
        !_isLikelyLatexParseUnsafe(latexCandidate);
    if (!isSafeMath) {
      return Text(
        '${c.label} ${_latexToPlainPreview(rendered)}',
        softWrap: true,
        style: textStyle,
      );
    }
    return Padding(
      padding: EdgeInsets.only(bottom: hasFraction ? 2.4 : 1.2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Padding(
            padding: EdgeInsets.only(top: hasFraction ? 1.4 : 0.2),
            child: Text('${c.label} ', style: textStyle),
          ),
          Expanded(
            child: ClipRect(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const NeverScrollableScrollPhysics(),
                child: Math.tex(
                  latexCandidate,
                  mathStyle: hasFraction ? MathStyle.display : MathStyle.text,
                  textStyle: textStyle.copyWith(
                      fontSize: 10.9, height: hasFraction ? 1.52 : 1.38),
                  onErrorFallback: (dynamic _) => Text(
                    _latexToPlainPreview(rendered),
                    softWrap: true,
                    style: textStyle,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEquationPreview2D(String eq) {
    const style = TextStyle(
      color: Color(0xFF2F4A9E),
      fontSize: 10.8,
      height: 1.48,
    );
    final latexCandidate = _sanitizeLatexForMathTex(eq);
    final hasFraction = _containsFractionExpression(latexCandidate);
    final isSafeMath = _looksLikeMathCandidate(latexCandidate) &&
        !_isLikelyLatexParseUnsafe(latexCandidate);
    if (!isSafeMath) {
      return Text(
        _latexToPlainPreview(eq),
        softWrap: true,
        style: style,
      );
    }
    return Container(
      width: double.infinity,
      padding:
          EdgeInsets.symmetric(horizontal: 2, vertical: hasFraction ? 3 : 2),
      decoration: BoxDecoration(
        color: const Color(0x142F4A9E),
        borderRadius: BorderRadius.circular(4),
      ),
      child: ClipRect(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          child: Math.tex(
            latexCandidate,
            mathStyle: hasFraction ? MathStyle.display : MathStyle.text,
            textStyle: style.copyWith(height: hasFraction ? 1.56 : 1.42),
            onErrorFallback: (dynamic _) => Text(
              _latexToPlainPreview(eq),
              softWrap: true,
              style: style,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPdfPreviewThumbnail(ProblemBankQuestion q) {
    final stemPreview = _stemHeadlinePreview(q);
    final viewBlockLines = _viewBlockPreviewLines(q);
    return Container(
      height: 219,
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
        child: ClipRect(
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            child: DefaultTextStyle(
              style: const TextStyle(
                color: Color(0xFF232323),
                fontSize: 11.4,
                height: 1.34,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LatexTextRenderer(
                    _toPreviewMathMarkup('${q.questionNumber}. $stemPreview'),
                    softWrap: true,
                    enableDisplayMath: false,
                    style: const TextStyle(height: 1.48),
                  ),
                  if (viewBlockLines.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 5),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF7F8FB),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: const Color(0xFFE4E7EE)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final line in viewBlockLines.take(6))
                            Padding(
                              padding: const EdgeInsets.only(bottom: 3),
                              child: LatexTextRenderer(
                                _toPreviewMathMarkup(line),
                                softWrap: true,
                                enableDisplayMath: false,
                                style: const TextStyle(
                                  color: Color(0xFF3A3A3A),
                                  fontSize: 10.8,
                                  height: 1.46,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                  if (q.choices.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    for (final choice in q.choices.take(5))
                      _buildChoicePreviewLine(q, choice),
                  ],
                  if (_firstEquationPreview(q).isNotEmpty) ...[
                    const SizedBox(height: 4),
                    _buildEquationPreview2D(_firstEquationPreview(q)),
                  ],
                  if (q.figureRefs.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    const Text(
                      '[그림/도표 포함]',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(color: Color(0xFF505050), fontSize: 10.5),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildQuestionGridCard(ProblemBankQuestion q) {
    final confidenceColor = q.confidence >= 0.9
        ? const Color(0xFF41B883)
        : (q.confidence >= 0.8
            ? const Color(0xFFE3B341)
            : const Color(0xFFDE6A73));
    final typeText = q.questionType.trim().isEmpty ? '미분류' : q.questionType;
    final isViewBlock = _isViewBlockQuestion(q);
    final previewLine = _compactPreviewText(q.renderedStem, maxChars: 62);
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
          const SizedBox(height: 8),
          const Text(
            'PDF 미리보기',
            style: TextStyle(color: _textSub, fontSize: 11),
          ),
          const SizedBox(height: 4),
          _buildPdfPreviewThumbnail(q),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  previewLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _textSub,
                    fontSize: 11.5,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
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
                      mainAxisExtent: 407,
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
