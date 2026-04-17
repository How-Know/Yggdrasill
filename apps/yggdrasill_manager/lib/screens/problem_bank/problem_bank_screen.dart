import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/problem_bank_service.dart';
import '../../widgets/latex_text_renderer.dart';
import 'problem_bank_models.dart';
import 'widgets/figure_compare_dialog.dart';
import 'widgets/problem_bank_classification_filter_panel.dart';
import 'widgets/problem_bank_mode_tab_bar.dart';
import 'widgets/problem_bank_synced_list_dialog.dart';

class ProblemBankScreen extends StatefulWidget {
  const ProblemBankScreen({super.key});

  @override
  State<ProblemBankScreen> createState() => _ProblemBankScreenState();
}

class _ProblemBankScreenState extends State<ProblemBankScreen>
    with SingleTickerProviderStateMixin {
  static const Color _bg = Color(0xFF0B1112);
  static const Color _panel = Color(0xFF10171A);
  static const Color _field = Color(0xFF15171C);
  static const Color _border = Color(0xFF223131);
  static const Color _text = Color(0xFFEAF2F2);
  static const Color _textSub = Color(0xFF9FB3B3);
  static const Color _accent = Color(0xFF33A373);
  static const String _previewKoreanFontFamily = 'HCRBatang';
  static const double _previewMathScale = 1.10;
  // 분수는 명령(\dfrac) 승격으로 키우고, 식 전체 스케일은 일반 수식과 동일하게 유지한다.
  static const double _previewFractionMathScale = _previewMathScale;

  static const Map<String, String> _curriculumLabels = <String, String>{
    'legacy_1to6': '옛날 교육과정(1~6차)',
    'k7_1997': '7차 교육과정(1997)',
    'k7_2007': '2007 개정(7차)',
    'rev_2009': '2009 개정',
    'rev_2015': '2015 개정',
    'rev_2022': '2022 개정',
  };
  static const Map<String, String> _sourceTypeLabels = <String, String>{
    'market_book': '시중 교재',
    'lecture_book': '인강 교재',
    'ebs_book': 'EBS 교재',
    'school_past': '내신 기출',
    'mock_past': '모의고사 기출',
    'original_item': '자작 문항',
  };
  static const Map<String, String> _questionTypeFilterLabels = <String, String>{
    '': '전체',
    '객관식': '객관식',
    '주관식': '주관식',
    '서술형': '서술형',
  };
  static const List<String> _courseLabelOptions = <String>[
    '',
    '중등',
    '고등',
    '공통',
  ];
  static const Map<String, String> _courseLabelLabels = <String, String>{
    '': '미선택',
    '중등': '중등',
    '고등': '고등',
    '공통': '공통',
  };

  final ProblemBankService _service = ProblemBankService();
  late final TabController _topTabController;

  Timer? _pollTimer;
  Timer? _previewPollTimer;
  bool _bootstrapLoading = true;
  bool _isUploading = false;
  bool _isExtracting = false;
  bool _isResetting = false;
  bool _hasExtracted = false;
  bool _showLowConfidenceOnly = false;
  bool _schemaMissing = false;
  bool _academyMissing = false;
  String _statusText = '초기화 중...';

  String? _academyId;
  // '목록' 다이얼로그에서 가장 최근에 사용한 레벨/세부 과정 (기본 '전체').
  final String _syncedListSchoolLevel = '전체';
  final String _syncedListDetailedCourse = '전체';

  List<ProblemBankDocument> _documents = <ProblemBankDocument>[];
  ProblemBankDocument? _activeDocument;
  ProblemBankExtractJob? _activeExtractJob;
  List<ProblemBankQuestion> _questions = <ProblemBankQuestion>[];
  final List<_PipelineLogEntry> _pipelineLogs = <_PipelineLogEntry>[];
  final Map<String, String> _questionPreviewUrls = <String, String>{};
  final Map<String, String> _questionPreviewPdfUrls = <String, String>{};
  final Map<String, String> _questionPreviewStatus = <String, String>{};
  final Map<String, String> _questionPreviewErrors = <String, String>{};
  final Set<String> _pendingPreviewQuestionIds = <String>{};
  final Map<String, String> _figurePreviewUrls = <String, String>{};
  final Map<String, String> _figurePreviewPaths = <String, String>{};
  final Map<String, Map<String, String>> _figurePreviewUrlsByPath =
      <String, Map<String, String>>{};
  final Set<String> _figureGenerating = <String>{};
  final Map<String, String> _scoreDrafts = <String, String>{};
  final TextEditingController _sourceYearCtrl = TextEditingController();
  final TextEditingController _sourceSchoolCtrl = TextEditingController();
  final TextEditingController _sourceGradeCtrl = TextEditingController();
  final TextEditingController _sourcePublisherCtrl = TextEditingController();
  final TextEditingController _sourceMaterialCtrl = TextEditingController();
  final TextEditingController _classificationYearFilterCtrl =
      TextEditingController();
  final TextEditingController _classificationGradeFilterCtrl =
      TextEditingController();
  final TextEditingController _classificationSchoolFilterCtrl =
      TextEditingController();
  final Set<String> _dirtyQuestionIds = <String>{};
  final Set<String> _reextractingQuestionIds = <String>{};
  bool _isSavingQuestionChanges = false;
  bool _isDeletingCurrentQuestions = false;
  bool _isDeletingClassificationDocument = false;
  bool _dirtyDocumentMeta = false;
  bool _needsPublish = false;
  String _selectedCurriculumCode = 'rev_2022';
  String _selectedSourceTypeCode = 'school_past';
  String _selectedCourseLabel = '';
  String _sourceSemester = '1학기';
  String _sourceExamTerm = '';
  String _classificationCurriculumFilter = '';
  String _classificationSourceTypeFilter = '';
  String _classificationQuestionTypeFilter = '';
  bool _isSearchingClassification = false;
  List<_ClassificationDocumentResult> _classificationResults =
      <_ClassificationDocumentResult>[];
  bool _isFigurePolling = false;
  String? _lastExtractStatus;
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

  bool get _documentDbReady =>
      (_activeDocument?.status ?? '').trim().toLowerCase() == 'ready';

  bool get _progressIndeterminate {
    final extractStatus = _activeExtractJob?.status ?? '';
    return _isResetting ||
        extractStatus == 'queued' ||
        extractStatus == 'extracting' ||
        _isFigurePolling ||
        _figureGenerating.isNotEmpty;
  }

  double get _progressValue {
    if (_isResetting) return 0.03;
    if (_documentDbReady) return 1.0;
    final extractStatus = _activeExtractJob?.status ?? '';
    if (_isUploading) return 0.15;
    if (_activeDocument != null && extractStatus.isEmpty && !_hasExtracted) {
      return 0.22;
    }
    if (extractStatus == 'queued' || extractStatus == 'extracting') {
      return 0.35;
    }
    if (extractStatus == 'review_required' ||
        extractStatus == 'completed' ||
        _hasExtracted) {
      if (_isFigurePolling || _figureGenerating.isNotEmpty) return 0.75;
      if (_checkedCount == 0) return 0.52;
      if (_needsPublish) return 0.95;
      return 0.68;
    }
    return 0.0;
  }

  String get _progressLabel {
    final extractStatus = _activeExtractJob?.status ?? '';
    if (_isResetting) return '이전 작업 초기화 중 (0/3)';
    if (_isUploading) return '업로드 중 (1/3)';
    if (_documentDbReady) return 'DB화 완료 (3/3)';
    if (_activeDocument != null && extractStatus.isEmpty && !_hasExtracted) {
      return '업로드 완료 · 자동 추출 준비 (1/3)';
    }
    if (extractStatus == 'queued') {
      final elapsed = _extractQueuedElapsed;
      if (elapsed == null) return '추출 대기열 등록됨 (1/3)';
      return '추출 대기열 대기 중 (1/3, ${_formatElapsed(elapsed)})';
    }
    if (extractStatus == 'extracting') return '한글/수식 추출 중 (1/3)';
    if (extractStatus == 'review_required' || extractStatus == 'completed') {
      if (_isFigurePolling || _figureGenerating.isNotEmpty) {
        return 'AI 그림 생성 중 (2/3)';
      }
      if (_checkedCount == 0) return '검수 대기 중 (2/3)';
      if (_needsPublish) return 'DB 반영(업로드) 대기 (2/3)';
      return '검수 진행 중 (2/3)';
    }
    if (_hasExtracted) {
      if (_isFigurePolling || _figureGenerating.isNotEmpty) {
        return 'AI 그림 생성 중 (2/3)';
      }
      if (_checkedCount == 0) return '검수 대기 중 (2/3)';
      if (_needsPublish) return 'DB 반영(업로드) 대기 (2/3)';
      return '검수 진행 중 (2/3)';
    }
    return '대기 중';
  }

  @override
  void initState() {
    super.initState();
    _topTabController = TabController(length: 2, vsync: this);
    _topTabController.addListener(() {
      if (_topTabController.indexIsChanging) return;
      if (_topTabController.index == 1) {
        unawaited(_runClassificationSearch());
      }
    });
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _previewPollTimer?.cancel();
    _topTabController.dispose();
    _sourceYearCtrl.dispose();
    _sourceSchoolCtrl.dispose();
    _sourceGradeCtrl.dispose();
    _sourcePublisherCtrl.dispose();
    _sourceMaterialCtrl.dispose();
    _classificationYearFilterCtrl.dispose();
    _classificationGradeFilterCtrl.dispose();
    _classificationSchoolFilterCtrl.dispose();
    super.dispose();
  }

  bool get _isSchoolPastSource => _selectedSourceTypeCode == 'school_past';

  bool get _isPrivateSource =>
      _selectedSourceTypeCode == 'market_book' ||
      _selectedSourceTypeCode == 'lecture_book' ||
      _selectedSourceTypeCode == 'ebs_book';

  String _labelOfCurriculumCode(String code) => _curriculumLabels[code] ?? code;

  String _labelOfSourceTypeCode(String code) => _sourceTypeLabels[code] ?? code;

  bool _isDraftDocumentStatus(String status) {
    final safe = status.trim().toLowerCase();
    return safe.isNotEmpty && safe != 'ready';
  }

  String _labelOfDocumentStatus(String status) {
    final safe = status.trim().toLowerCase();
    switch (safe) {
      case 'ready':
        return '확정본';
      case 'draft_ready':
        return '작업본(업로드 대기)';
      case 'draft_review_required':
        return '작업본(검수 필요)';
      case 'extract_queued':
        return '작업본(추출 대기)';
      case 'uploaded':
        return '작업본(추출 전)';
      case 'review_required':
        return '작업본(검수 필요)';
      case 'completed':
        return '작업본(검수 전)';
      case '':
        return '상태 없음';
      default:
        return _isDraftDocumentStatus(safe) ? '작업본' : safe;
    }
  }

  int? _sourceExamYearValue() {
    final text = _sourceYearCtrl.text.trim();
    if (text.isEmpty) return null;
    return int.tryParse(text.replaceAll(RegExp(r'[^0-9]'), ''));
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

  void _applySourceMetaFromDocument(ProblemBankDocument? doc) {
    final meta = doc?.meta ?? const <String, dynamic>{};
    final sourceRaw = meta['source_classification'];
    final source = sourceRaw is Map
        ? sourceRaw.map((k, dynamic v) => MapEntry('$k', v))
        : const <String, dynamic>{};
    final naesinRaw = source['naesin'];
    final naesin = naesinRaw is Map
        ? naesinRaw.map((k, dynamic v) => MapEntry('$k', v))
        : const <String, dynamic>{};

    final fallbackSourceType = source['private_material'] == true
        ? 'market_book'
        : source['mock_past_exam'] == true
            ? 'mock_past'
            : source['school_past_exam'] == true
                ? 'school_past'
                : 'school_past';

    final curriculumCode = (doc?.curriculumCode ?? '').trim();
    _selectedCurriculumCode = _curriculumLabels.containsKey(curriculumCode)
        ? curriculumCode
        : 'rev_2022';
    final sourceTypeCode = (doc?.sourceTypeCode ?? '').trim();
    _selectedSourceTypeCode = _sourceTypeLabels.containsKey(sourceTypeCode)
        ? sourceTypeCode
        : fallbackSourceType;
    _selectedCourseLabel = _courseLabelOptions.contains(doc?.courseLabel)
        ? (doc?.courseLabel ?? '')
        : '';

    _sourceYearCtrl.text =
        doc?.examYear?.toString() ?? '${naesin['year'] ?? ''}'.trim();
    _sourceSchoolCtrl.text = (doc?.schoolName ?? '').trim().isNotEmpty
        ? doc!.schoolName
        : '${naesin['school_name'] ?? ''}'.trim();
    _sourceGradeCtrl.text = (doc?.gradeLabel ?? '').trim().isNotEmpty
        ? doc!.gradeLabel
        : '${naesin['grade'] ?? ''}'.trim();
    _sourcePublisherCtrl.text = doc?.publisherName ?? '';
    _sourceMaterialCtrl.text = doc?.materialName ?? '';

    final semester = (doc?.semesterLabel ?? '').trim().isNotEmpty
        ? doc!.semesterLabel
        : '${naesin['semester'] ?? ''}'.trim();
    _sourceSemester = semester == '2학기' || semester == '1학기' ? semester : '1학기';
    final examTerm = (doc?.examTermLabel ?? '').trim().isNotEmpty
        ? doc!.examTermLabel
        : '${naesin['exam_term'] ?? ''}'.trim();
    _sourceExamTerm = examTerm == '중간' || examTerm == '기말' ? examTerm : '';
    _dirtyDocumentMeta = false;
  }

  Map<String, dynamic> _buildSourceClassificationMeta() {
    final isPrivate = _isPrivateSource;
    return <String, dynamic>{
      'private_material': isPrivate,
      'school_past_exam': _selectedSourceTypeCode == 'school_past',
      'mock_past_exam': _selectedSourceTypeCode == 'mock_past',
      'naesin': <String, dynamic>{
        'year': _sourceYearCtrl.text.trim(),
        'school_name': _sourceSchoolCtrl.text.trim(),
        'grade': _sourceGradeCtrl.text.trim(),
        'semester': _sourceSemester,
        'exam_term': _sourceExamTerm,
      },
    };
  }

  Map<String, dynamic> _buildClassificationDetailPayload() {
    return <String, dynamic>{
      'source_classification': _buildSourceClassificationMeta(),
      'updated_from': 'manager',
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
  }

  void _markDocumentMetaDirty() {
    if (!mounted) return;
    if (_dirtyDocumentMeta) return;
    setState(() {
      _dirtyDocumentMeta = true;
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

  static const double _figureScaleMin = 0.3;
  static const double _figureScaleMax = 2.2;
  static const double _figureWidthEmMin = 5.0;
  static const double _figureWidthEmMax = 30.0;
  static const double _figureWidthEmDefault = 15.5;
  static const double _defaultStemSizePt = 11.0;
  static const double _defaultMaxHeightPt = 170.0;

  static const List<String> _figurePositionOptions = <String>[
    'below-stem',
    'inline-right',
    'inline-left',
    'between-stem-choices',
    'above-choices',
  ];
  static const Map<String, String> _figurePositionLabels = <String, String>{
    'below-stem': '본문 아래',
    'inline-right': '본문 오른쪽',
    'inline-left': '본문 왼쪽',
    'between-stem-choices': '본문-보기 사이',
    'above-choices': '보기 위',
  };

  double _scaleToWidthEm(double scale) {
    final safeScale = scale.clamp(_figureScaleMin, _figureScaleMax);
    final maxHeightPt = _defaultMaxHeightPt * safeScale;
    return (maxHeightPt / _defaultStemSizePt * 100).roundToDouble() / 100.0;
  }

  double _widthEmToScale(double widthEm) {
    final widthPt = widthEm.clamp(_figureWidthEmMin, _figureWidthEmMax) *
        _defaultStemSizePt;
    final scale = widthPt / _defaultMaxHeightPt;
    return scale.clamp(_figureScaleMin, _figureScaleMax);
  }

  double _normalizeFigureScale(double value) {
    if (!value.isFinite) return 1.0;
    return value.clamp(_figureScaleMin, _figureScaleMax).toDouble();
  }

  Map<String, double> _figureRenderScaleMapOf(ProblemBankQuestion q) {
    final raw = q.meta['figure_render_scales'];
    if (raw is! Map) return const <String, double>{};
    final out = <String, double>{};
    raw.forEach((key, value) {
      final safeKey = '$key'.trim();
      if (safeKey.isEmpty) return;
      final parsed =
          value is num ? value.toDouble() : double.tryParse('$value');
      if (parsed == null || !parsed.isFinite) return;
      out[safeKey] = _normalizeFigureScale(parsed);
    });
    return out;
  }

  String _figureScaleKeyForAsset(Map<String, dynamic>? asset, int order) {
    final index = int.tryParse('${asset?['figure_index'] ?? ''}');
    if (index != null && index > 0) return 'idx:$index';
    final path = '${asset?['path'] ?? ''}'.trim();
    if (path.isNotEmpty) return 'path:$path';
    return 'ord:$order';
  }

  String _figureScaleKeyLabel(String key, int fallbackOrder) {
    if (key.startsWith('idx:')) {
      final n = int.tryParse(key.substring(4));
      if (n != null && n > 0) return '그림 $n';
    }
    if (key.startsWith('ord:')) {
      final n = int.tryParse(key.substring(4));
      if (n != null && n > 0) return '그림 $n';
    }
    return '그림 $fallbackOrder';
  }

  String _figurePairKey(String keyA, String keyB) {
    final a = keyA.trim();
    final b = keyB.trim();
    if (a.isEmpty || b.isEmpty || a == b) return '';
    return a.compareTo(b) <= 0 ? '$a|$b' : '$b|$a';
  }

  List<String> _figurePairParts(String pairKey) {
    final i = pairKey.indexOf('|');
    if (i <= 0 || i >= pairKey.length - 1) return const <String>[];
    final a = pairKey.substring(0, i).trim();
    final b = pairKey.substring(i + 1).trim();
    if (a.isEmpty || b.isEmpty || a == b) return const <String>[];
    return <String>[a, b];
  }

  Set<String> _figureHorizontalPairKeysOf(ProblemBankQuestion q) {
    final raw = q.meta['figure_horizontal_pairs'];
    if (raw is! List) return const <String>{};
    final out = <String>{};
    for (final item in raw) {
      if (item is! Map) continue;
      final map =
          Map<String, dynamic>.from(item.map((k, v) => MapEntry('$k', v)));
      final key = _figurePairKey(
        '${map['a'] ?? map['left'] ?? ''}',
        '${map['b'] ?? map['right'] ?? ''}',
      );
      if (key.isNotEmpty) out.add(key);
    }
    return out;
  }


  double _figureRenderScaleOf(ProblemBankQuestion q) {
    final raw = q.meta['figure_render_scale'];
    final parsed = raw is num ? raw.toDouble() : double.tryParse('$raw');
    if (parsed != null && parsed.isFinite) {
      return _normalizeFigureScale(parsed);
    }
    final map = _figureRenderScaleMapOf(q);
    if (map.isEmpty) return 1.0;
    final avg = map.values.fold<double>(0.0, (sum, v) => sum + v) / map.length;
    return _normalizeFigureScale(avg);
  }

  double _figureRenderScaleForAsset(
    ProblemBankQuestion q, {
    Map<String, dynamic>? asset,
    int order = 1,
  }) {
    final scaleMap = _figureRenderScaleMapOf(q);
    if (scaleMap.isEmpty) return _figureRenderScaleOf(q);
    final key = _figureScaleKeyForAsset(asset, order);
    final direct = scaleMap[key];
    if (direct != null) return direct;
    final index = int.tryParse('${asset?['figure_index'] ?? ''}');
    if (index != null) {
      final byIndex = scaleMap['idx:$index'];
      if (byIndex != null) return byIndex;
    }
    final path = '${asset?['path'] ?? ''}'.trim();
    if (path.isNotEmpty) {
      final byPath = scaleMap['path:$path'];
      if (byPath != null) return byPath;
    }
    return _figureRenderScaleOf(q);
  }

  String _figureRenderScaleLabel(ProblemBankQuestion q) {
    final pct = (_figureRenderScaleOf(q) * 100).round();
    return '$pct%';
  }

  void _setFigureRenderScales(
    ProblemBankQuestion q,
    Map<String, double> widthEmMap, {
    Map<String, String>? positionMap,
    Set<String>? horizontalPairKeys,
  }) {
    final updatedMeta = Map<String, dynamic>.from(q.meta);

    final items = <Map<String, dynamic>>[];
    for (final e in widthEmMap.entries) {
      final key = e.key.trim();
      if (key.isEmpty) continue;
      final wEm = e.value.clamp(_figureWidthEmMin, _figureWidthEmMax);
      final pos = positionMap?[key] ?? 'below-stem';
      items.add(<String, dynamic>{
        'assetKey': key,
        'widthEm': (wEm * 10).roundToDouble() / 10.0,
        'position': pos,
        'anchor': 'center',
        'offsetXEm': 0,
        'offsetYEm': 0,
      });
    }

    final nextPairKeys = horizontalPairKeys ?? _figureHorizontalPairKeysOf(q);
    final groups = <Map<String, dynamic>>[];
    for (final pairKey in nextPairKeys) {
      final parts = _figurePairParts(pairKey);
      if (parts.length != 2) continue;
      groups.add(<String, dynamic>{
        'type': 'horizontal',
        'members': parts,
        'gap': 0.5,
      });
    }

    if (items.isNotEmpty) {
      updatedMeta['figure_layout'] = <String, dynamic>{
        'version': 1,
        'items': items,
        'groups': groups,
      };
    } else {
      updatedMeta.remove('figure_layout');
    }

    final legacyScaleMap = <String, dynamic>{};
    for (final e in widthEmMap.entries) {
      final key = e.key.trim();
      if (key.isEmpty) continue;
      final scale = _widthEmToScale(e.value);
      if ((scale - 1.0).abs() < 0.01) continue;
      legacyScaleMap[key] = (scale * 100).roundToDouble() / 100.0;
    }
    if (legacyScaleMap.isEmpty) {
      updatedMeta.remove('figure_render_scales');
    } else {
      updatedMeta['figure_render_scales'] = legacyScaleMap;
    }
    final cleanedPairPayload = nextPairKeys
        .map((pairKey) => _figurePairParts(pairKey))
        .where((parts) => parts.length == 2)
        .map((parts) => <String, String>{'a': parts[0], 'b': parts[1]})
        .toList(growable: false);
    if (cleanedPairPayload.isEmpty) {
      updatedMeta.remove('figure_horizontal_pairs');
    } else {
      updatedMeta['figure_horizontal_pairs'] = cleanedPairPayload;
    }
    final avgScale = widthEmMap.isEmpty
        ? 1.0
        : widthEmMap.values
                .map((w) => _widthEmToScale(w))
                .fold<double>(0.0, (sum, v) => sum + v) /
            widthEmMap.length;
    final normalizedGlobal = _normalizeFigureScale(avgScale);
    if ((normalizedGlobal - 1.0).abs() < 0.01) {
      updatedMeta.remove('figure_render_scale');
    } else {
      updatedMeta['figure_render_scale'] =
          (normalizedGlobal * 100).roundToDouble() / 100.0;
    }

    if (!mounted) return;
    setState(() {
      _questions = _questions
          .map((item) =>
              item.id == q.id ? item.copyWith(meta: updatedMeta) : item)
          .toList(growable: false);
      _dirtyQuestionIds.add(q.id);
    });
    final pairSuffix = cleanedPairPayload.isEmpty
        ? ''
        : ' · 가로묶음 ${cleanedPairPayload.length}쌍';
    _showSnack(
      '${q.questionNumber}번 그림 설정을 저장했습니다.$pairSuffix 상단 `업로드` 버튼으로 반영하세요.',
    );
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

  Future<void> _prefetchQuestionPreviewUrls(
    List<ProblemBankQuestion> questions,
  ) async {
    final academyId = _academyId;
    if (academyId == null || academyId.isEmpty || questions.isEmpty) return;
    if (!_service.hasGateway) return;

    final ordered = questions
        .where((q) => q.id.trim().isNotEmpty)
        .toList(growable: false);
    if (ordered.isEmpty) {
      if (mounted) {
        setState(() {
          _questionPreviewUrls.clear();
          _questionPreviewPdfUrls.clear();
          _questionPreviewStatus.clear();
          _questionPreviewErrors.clear();
          _pendingPreviewQuestionIds.clear();
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        for (final q in ordered) {
          _questionPreviewStatus[q.id.trim()] = 'rendering';
        }
      });
    }

    final questionIds = ordered
        .map((q) => q.questionUid.trim().isNotEmpty ? q.questionUid.trim() : q.id.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    if (questionIds.isEmpty) return;

    final activeDocument = _activeDocument;
    final documentId = activeDocument?.id.trim() ?? '';
    const profile = 'naesin';
    const paperSize = 'A4';

    try {
      final urlMap = await _service.batchRenderThumbnails(
        academyId: academyId,
        questionIds: questionIds,
        documentId: documentId,
        templateProfile: profile,
        paperSize: paperSize,
      );
      if (!mounted) return;

      final uidToId = <String, String>{};
      for (final q in ordered) {
        final id = q.id.trim();
        final uid = q.questionUid.trim();
        if (id.isNotEmpty) uidToId[id] = id;
        if (uid.isNotEmpty && uid != id) uidToId[uid] = id;
      }

      setState(() {
        for (final entry in urlMap.entries) {
          final qid = uidToId[entry.key.trim()] ?? entry.key.trim();
          if (qid.isEmpty) continue;
          _questionPreviewUrls[qid] = entry.value;
          _questionPreviewStatus[qid] = 'completed';
          _questionPreviewErrors.remove(qid);
        }
        for (final q in ordered) {
          final id = q.id.trim();
          if (id.isNotEmpty && !_questionPreviewUrls.containsKey(id)) {
            _questionPreviewStatus[id] = 'failed';
            _questionPreviewErrors[id] = '서버 미리보기 응답에서 누락되었습니다.';
          }
        }
        _pendingPreviewQuestionIds.clear();
      });
    } catch (err) {
      if (!mounted) return;
      final msg = err.toString().trim();
      setState(() {
        for (final q in ordered) {
          final id = q.id.trim();
          if (id.isEmpty) continue;
          _questionPreviewStatus[id] = 'failed';
          _questionPreviewErrors[id] = msg.isNotEmpty ? msg : '서버 미리보기에 실패했습니다.';
        }
        _pendingPreviewQuestionIds.clear();
      });
    }
  }

  void _retryQuestionPreview(String questionId) {
    final targets = _questions.where((q) => q.id == questionId).toList();
    if (targets.isEmpty) return;
    unawaited(_prefetchQuestionPreviewUrls(targets));
  }

  Future<String?> _saveAndRefreshPreview(ProblemBankQuestion q) async {
    final academyId = _academyId;
    if (academyId == null || academyId.isEmpty) return null;
    final qId = q.id.trim();
    if (qId.isEmpty) return null;
    try {
      final mergedMeta = Map<String, dynamic>.from(q.meta);
      final parsedScore = _parseScoreDraft(_scoreDraftFor(q));
      if (parsedScore == null) {
        mergedMeta.remove('score_point');
      } else {
        final rounded = parsedScore.roundToDouble();
        mergedMeta['score_point'] =
            rounded == parsedScore ? rounded.toInt() : parsedScore;
      }
      await _service.updateQuestionReview(
        questionId: qId,
        isChecked: q.isChecked,
        reviewerNotes: q.reviewerNotes,
        questionType: q.questionType,
        stem: q.stem,
        choices: q.choices,
        allowObjective: q.allowObjective,
        allowSubjective: q.allowSubjective,
        objectiveChoices: q.objectiveChoices,
        objectiveAnswerKey: q.objectiveAnswerKey.trim().isEmpty
            ? null
            : q.objectiveAnswerKey.trim(),
        subjectiveAnswer: q.subjectiveAnswer.trim().isEmpty
            ? null
            : q.subjectiveAnswer.trim(),
        objectiveGenerated: q.objectiveGenerated,
        equations: q.equations,
        meta: mergedMeta,
      );
      if (!mounted) return null;
      await _prefetchQuestionPreviewUrls(<ProblemBankQuestion>[q]);
      final newUrl = (_questionPreviewUrls[qId] ?? '').trim();
      if (!mounted) return null;
      setState(() {
        _dirtyQuestionIds.remove(qId);
        if (newUrl.isNotEmpty) {
          _questionPreviewUrls[qId] = newUrl;
        } else {
          _questionPreviewUrls.remove(qId);
        }
      });
      return newUrl.isNotEmpty ? newUrl : null;
    } catch (e) {
      if (mounted) {
        setState(() => _dirtyQuestionIds.add(qId));
      }
      _showSnack('문항 저장·미리보기 갱신 실패: $e', error: true);
      return null;
    }
  }

  Future<void> _openFigureCompareDialog(ProblemBankQuestion q) async {
    final academyId = _academyId;
    if (academyId == null) return;
    final doc = _activeDocument;
    if (doc == null) return;

    final originalAssets = List<Map<String, dynamic>>.from(
      _figureAssetsOf(q).map((a) => Map<String, dynamic>.from(a)),
    );

    final orderedAssets = _orderedFigureAssetsOf(q);
    final currentUrls = <int, String>{};
    for (var i = 0; i < orderedAssets.length; i++) {
      final path = '${orderedAssets[i]['path'] ?? ''}'.trim();
      if (path.isEmpty) continue;
      final url = _figurePreviewUrlForPath(q.id, path);
      if (url.isNotEmpty) {
        currentUrls[i] = url;
      } else {
        final bucket = '${orderedAssets[i]['bucket'] ?? ''}'.trim();
        if (bucket.isNotEmpty) {
          try {
            final signed = await _service.createStorageSignedUrl(
              bucket: bucket,
              path: path,
              expiresInSeconds: 3600,
            );
            if (signed.isNotEmpty) currentUrls[i] = signed;
          } catch (_) {}
        }
      }
    }

    if (!mounted) return;
    final result = await FigureCompareDialog.show(
      context: context,
      service: _service,
      academyId: academyId,
      documentId: doc.id,
      question: q,
      currentFigureUrls: currentUrls,
    );

    if (result == null) return;

    if (!result.accepted) {
      await _rollbackFigureAssets(q, originalAssets);
      return;
    }

    await _reloadQuestions();
    await _prefetchFigurePreviewUrls(
      _questions.where((qq) => qq.id == q.id).toList(),
    );
    _appendPipelineLog(
        'figure', '${q.questionNumber}번 AI 그림 적용 완료');
    _showSnack('${q.questionNumber}번 AI 그림이 적용되었습니다.');
  }

  Future<void> _rollbackFigureAssets(
    ProblemBankQuestion q,
    List<Map<String, dynamic>> originalAssets,
  ) async {
    try {
      final currentMeta = Map<String, dynamic>.from(q.meta);
      currentMeta['figure_assets'] = originalAssets;
      await _service.updateQuestionMeta(
        questionId: q.id,
        meta: currentMeta,
      );
      await _reloadQuestions();
    } catch (e) {
      _appendPipelineLog(
          'figure', '${q.questionNumber}번 원본 복원 실패: $e', error: true);
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
    if (!mounted) return;
    setState(() {
      _questions = _questions
          .map((item) =>
              item.id == q.id ? item.copyWith(meta: updatedMeta) : item)
          .toList(growable: false);
      _dirtyQuestionIds.add(q.id);
    });
    _showSnack(
      approved
          ? '${q.questionNumber}번 AI 그림 승인 상태를 수정했습니다. `업로드` 버튼으로 반영하세요.'
          : '${q.questionNumber}번 AI 그림 승인 해제 상태를 수정했습니다. `업로드` 버튼으로 반영하세요.',
    );
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
      if (_topTabController.index == 1) {
        unawaited(_runClassificationSearch());
      }
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
    if (_isResetting || _isUploading || _isExtracting) {
      return;
    }
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
                '이 학원의 문제은행 문서·추출·검수·DB화 이력을 모두 삭제합니다.\n'
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
        _questions = <ProblemBankQuestion>[];
        _dirtyQuestionIds.clear();
        _applySourceMetaFromDocument(null);
        _questionPreviewUrls.clear();
        _figurePreviewUrls.clear();
        _figurePreviewPaths.clear();
        _figurePreviewUrlsByPath.clear();
        _figureGenerating.clear();
        _scoreDrafts.clear();
        _isFigurePolling = false;
        _hasExtracted = false;
        _isUploading = false;
        _isExtracting = false;
        _showLowConfidenceOnly = false;
        _needsPublish = false;
        _queuedLongWaitWarned = false;
        _lastExtractStatus = null;
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
      final documentStatus = summary.document.status.trim();
      final isDraftDocument = documentStatus.startsWith('draft_');
      final draftStatusText = documentStatus == 'draft_review_required'
          ? '저신뢰 문항 추출 완료 · 검수/수정 후 업로드 대기'
          : '추출 완료 · 업로드 대기';
      final figureJobsQueuedHint = int.tryParse(
              '${summary.latestExtractJob?.resultSummary['figureJobsQueued'] ?? 0}') ??
          0;
      setState(() {
        _activeDocument = summary.document;
        _activeExtractJob = summary.latestExtractJob;
        _questions = questions;
        _dirtyQuestionIds.clear();
        _applySourceMetaFromDocument(summary.document);
        _questionPreviewUrls.clear();
        _figurePreviewUrls.clear();
        _figurePreviewPaths.clear();
        _figurePreviewUrlsByPath.clear();
        _figureGenerating.clear();
        _scoreDrafts.clear();
        _isFigurePolling = false;
        _hasExtracted = questions.isNotEmpty;
        _isExtracting =
            extractStatus == 'queued' || extractStatus == 'extracting';
        _needsPublish =
            questions.isNotEmpty && summary.document.status.trim() != 'ready';
        _lastExtractStatus = extractStatus.isEmpty ? null : extractStatus;
        _isFigurePolling = figureJobsQueuedHint > 0;
        _statusText = isDraftDocument && questions.isNotEmpty
            ? draftStatusText
            : _formatStatusText(
                extractStatus: extractStatus,
                questionCount: questions.length,
              );
      });
      _appendPipelineLog(
        'doc',
        '문서 로드 완료: 문항 ${questions.length}건, extract=$extractStatus',
      );
      unawaited(_prefetchQuestionPreviewUrls(questions));
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
    required int questionCount,
  }) {
    if (extractStatus == 'extracting' || extractStatus == 'queued') {
      return '한글/수식 추출이 진행 중입니다...';
    }
    if (extractStatus == 'failed') {
      return '추출이 실패했습니다. 재시도를 진행해 주세요.';
    }
    if (questionCount > 0) {
      return '추출 결과 $questionCount문항을 불러왔습니다.';
    }
    if (_activeDocument != null) {
      return '업로드 완료. 자동 추출을 시작합니다...';
    }
    return '문서를 업로드하고 추출을 시작하세요.';
  }

  Future<void> _pickAndUploadHwpx() async {
    if (_isResetting || _isUploading || _isExtracting) {
      return;
    }
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
      _statusText = 'HWPX 업로드 중...';
      _queuedLongWaitWarned = false;
      _lastExtractStatus = null;
    });

    try {
      final uploaded = await _service.uploadDocument(
        academyId: academyId,
        bytes: bytes,
        originalName: fileName,
        curriculumCode: _selectedCurriculumCode,
        sourceTypeCode: _selectedSourceTypeCode,
        courseLabel: _selectedCourseLabel,
        gradeLabel: _sourceGradeCtrl.text.trim(),
        examYear: _sourceExamYearValue(),
        semesterLabel: _sourceSemester,
        examTermLabel: _sourceExamTerm,
        schoolName: _sourceSchoolCtrl.text.trim(),
        publisherName: _sourcePublisherCtrl.text.trim(),
        materialName: _sourceMaterialCtrl.text.trim(),
        classificationDetail: _buildClassificationDetailPayload(),
      );
      final reusedDraft = uploaded.meta['reused_existing_draft'] == true;
      _appendPipelineLog(
        'upload',
        reusedDraft
            ? '기존 작업본 덮어쓰기 완료: document=${uploaded.id}'
            : '업로드 완료: document=${uploaded.id}',
      );
      await _refreshDocuments();
      if (!mounted) return;
      setState(() {
        _activeDocument = uploaded;
        _activeExtractJob = null;
        _questions = <ProblemBankQuestion>[];
        _dirtyQuestionIds.clear();
        _dirtyDocumentMeta = false;
        _needsPublish = false;
        _applySourceMetaFromDocument(uploaded);
        _questionPreviewUrls.clear();
        _figurePreviewUrls.clear();
        _figurePreviewPaths.clear();
        _figurePreviewUrlsByPath.clear();
        _figureGenerating.clear();
        _scoreDrafts.clear();
        _isFigurePolling = false;
        _isUploading = false;
        _isExtracting = false;
        _statusText = reusedDraft
            ? '기존 작업본을 덮어썼습니다. 자동으로 추출을 시작합니다...'
            : '업로드 완료. 자동으로 추출을 시작합니다...';
      });
      _ensurePolling();
      _showSnack(
        reusedDraft
            ? '같은 파일 작업본을 덮어썼습니다. 추출을 자동으로 시작합니다.'
            : '업로드 완료. 추출을 자동으로 시작합니다.',
      );
      await _startExtractForActiveDocument();
    } catch (e) {
      _appendPipelineLog('upload', '업로드 요청 실패: $e', error: true);
      if (!mounted) return;
      setState(() {
        _isUploading = false;
        _isExtracting = false;
        _statusText = '업로드 실패';
      });
      _showSnack('업로드 실패: $e', error: true);
    }
  }

  Future<void> _startExtractForActiveDocument() async {
    if (_isResetting || _isUploading || _isExtracting) {
      return;
    }
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
    final doc = _activeDocument;
    if (doc == null) {
      _showSnack('먼저 HWPX를 업로드하고 문서를 선택해주세요.', error: true);
      return;
    }
    final extract = _activeExtractJob;
    if (extract != null &&
        extract.documentId == doc.id &&
        (extract.status == 'queued' || extract.status == 'extracting')) {
      _showSnack('이미 추출 작업이 진행 중입니다.');
      return;
    }

    _appendPipelineLog('extract', '추출 시작 요청: document=${doc.id}');
    setState(() {
      _isExtracting = true;
      _hasExtracted = false;
      _queuedLongWaitWarned = false;
      _reextractingQuestionIds.clear();
      _statusText = '추출 작업을 큐에 등록 중...';
    });
    try {
      final extractJob = await _service.createExtractJob(
        academyId: academyId,
        documentId: doc.id,
      );
      _appendPipelineLog(
        'extract',
        '추출 잡 생성: ${extractJob.id} (${extractJob.status})',
      );
      await _refreshDocuments();
      if (!mounted) return;
      setState(() {
        _activeExtractJob = extractJob;
        _reextractingQuestionIds.clear();
        _questions = <ProblemBankQuestion>[];
        _dirtyQuestionIds.clear();
        _dirtyDocumentMeta = false;
        _needsPublish = false;
        _questionPreviewUrls.clear();
        _figurePreviewUrls.clear();
        _figurePreviewPaths.clear();
        _figurePreviewUrlsByPath.clear();
        _figureGenerating.clear();
        _scoreDrafts.clear();
        _isFigurePolling = false;
        _isExtracting = true;
        _lastExtractStatus = extractJob.status;
        _statusText = '추출 작업을 큐에 등록했습니다.';
      });
      _ensurePolling();
      _showSnack('추출 요청이 완료되었습니다.');
    } catch (e) {
      _appendPipelineLog('extract', '추출 요청 실패: $e', error: true);
      if (!mounted) return;
      setState(() {
        _isExtracting = false;
        _statusText = '추출 요청 실패';
      });
      _showSnack('추출 요청 실패: $e', error: true);
    }
  }

  Future<void> _reextractQuestion(ProblemBankQuestion question) async {
    await _startPartialReextract(
      <ProblemBankQuestion>[question],
      fromCheckedBulk: false,
    );
  }

  Future<void> _reextractCheckedQuestions() async {
    final targets = _questions.where((q) => q.isChecked).toList(growable: false);
    if (targets.isEmpty) {
      _showSnack('체크된 문항이 없습니다.', error: true);
      return;
    }
    await _startPartialReextract(targets, fromCheckedBulk: true);
  }

  Future<void> _startPartialReextract(
    List<ProblemBankQuestion> targets, {
    required bool fromCheckedBulk,
  }) async {
    if (_isResetting ||
        _isUploading ||
        _isExtracting ||
        _isSavingQuestionChanges ||
        _isDeletingCurrentQuestions) {
      return;
    }
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
    final doc = _activeDocument;
    if (doc == null) {
      _showSnack('먼저 HWPX를 업로드하고 문서를 선택해주세요.', error: true);
      return;
    }
    final targetIds = targets
        .map((q) => q.id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (targetIds.isEmpty) {
      _showSnack('재추출할 문항 ID를 찾지 못했습니다.', error: true);
      return;
    }
    final extract = _activeExtractJob;
    if (extract != null &&
        extract.documentId == doc.id &&
        (extract.status == 'queued' || extract.status == 'extracting')) {
      _showSnack('이미 추출 작업이 진행 중입니다.');
      return;
    }

    final targetLabel = fromCheckedBulk
        ? '체크 문항 ${targetIds.length}건'
        : '${targets.first.questionNumber}번 문항';
    _appendPipelineLog('extract', '부분 재추출 요청: $targetLabel');
    if (!mounted) return;
    setState(() {
      _isExtracting = true;
      _queuedLongWaitWarned = false;
      _reextractingQuestionIds
        ..clear()
        ..addAll(targetIds);
      for (final id in targetIds) {
        _dirtyQuestionIds.remove(id);
        _questionPreviewUrls.remove(id);
      }
      _statusText = '$targetLabel 재추출 작업을 큐에 등록 중...';
    });
    try {
      final extractJob = await _service.createExtractJob(
        academyId: academyId,
        documentId: doc.id,
        targetQuestionIds: targetIds,
      );
      _appendPipelineLog(
        'extract',
        '부분 재추출 잡 생성: ${extractJob.id} (${extractJob.status})',
      );
      await _refreshDocuments();
      if (!mounted) return;
      setState(() {
        _activeExtractJob = extractJob;
        _lastExtractStatus = extractJob.status;
        _isExtracting = true;
        _statusText = '$targetLabel 재추출 작업을 큐에 등록했습니다.';
      });
      _ensurePolling();
      _showSnack('$targetLabel 재추출 요청이 완료되었습니다.');
    } catch (e) {
      _appendPipelineLog('extract', '부분 재추출 요청 실패: $e', error: true);
      if (!mounted) return;
      setState(() {
        _isExtracting = false;
        _reextractingQuestionIds.clear();
        _statusText = '부분 재추출 요청 실패';
      });
      _showSnack('$targetLabel 재추출 요청 실패: $e', error: true);
    }
  }

  Future<void> _openPasteImportDialog() async {
    if (_isResetting || _isUploading || _isExtracting) {
      return;
    }
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
      _statusText = '붙여넣기 텍스트를 문항으로 변환 중...';
      _lastExtractStatus = null;
      _queuedLongWaitWarned = false;
    });

    try {
      final imported = await _service.importPastedText(
        academyId: academyId,
        rawText: payload.rawText,
        sourceName: payload.sourceName.trim().isEmpty
            ? 'manual_paste.txt'
            : payload.sourceName.trim(),
        curriculumCode: _selectedCurriculumCode,
        sourceTypeCode: _selectedSourceTypeCode,
        courseLabel: _selectedCourseLabel,
        gradeLabel: _sourceGradeCtrl.text.trim(),
        examYear: _sourceExamYearValue(),
        semesterLabel: _sourceSemester,
        examTermLabel: _sourceExamTerm,
        schoolName: _sourceSchoolCtrl.text.trim(),
        publisherName: _sourcePublisherCtrl.text.trim(),
        materialName: _sourceMaterialCtrl.text.trim(),
        classificationDetail: _buildClassificationDetailPayload(),
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
        _dirtyQuestionIds.clear();
        _dirtyDocumentMeta = false;
        _needsPublish = imported.questionCount > 0;
        _applySourceMetaFromDocument(imported.document);
        _questionPreviewUrls.clear();
        _figurePreviewUrls.clear();
        _figurePreviewPaths.clear();
        _figurePreviewUrlsByPath.clear();
        _figureGenerating.clear();
        _scoreDrafts.clear();
        _isFigurePolling = false;
        _isUploading = false;
        _isExtracting = false;
        _hasExtracted = imported.questionCount > 0;
        _statusText = '수동 입력에서 ${imported.questionCount}문항을 생성했습니다.';
      });
      await _loadDocumentContext(imported.document.id);
      _showSnack(
        '복사/붙여넣기 문항 ${imported.questionCount}건을 추출했습니다. 검수 후 `업로드`를 눌러 반영하세요.',
      );
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
    final hasPendingFigure = _isFigurePolling || _figureGenerating.isNotEmpty;
    if (!hasPendingExtract && !hasPendingFigure) {
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
        final partialReextract = latest.resultSummary['partialReextract'] == true;
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
          if (latest.isTerminal) {
            _reextractingQuestionIds.clear();
          }
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
          } else if (partialReextract) {
            nextStatusText = latest.status == 'review_required'
                ? '선택 문항 재추출 완료 · 일부 저신뢰'
                : '선택 문항 재추출 완료';
          } else {
            nextStatusText = latest.status == 'review_required'
                ? '저신뢰 문항 추출 완료 · 검수/수정 후 업로드 대기'
                : '추출 완료 · 업로드 대기';
          }
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
        _dirtyQuestionIds.clear();
        _reextractingQuestionIds.clear();
        _questionPreviewUrls.clear();
        final ids = questions.map((q) => q.id).toSet();
        _scoreDrafts.removeWhere((id, _) => !ids.contains(id));
        _hasExtracted = questions.isNotEmpty;
        final currentDocStatus = _activeDocument?.status.trim() ?? '';
        _needsPublish = questions.isNotEmpty && currentDocStatus != 'ready';
        _isExtracting = false;
      });
      _appendPipelineLog('review', '문항 목록 갱신: ${questions.length}건');
      unawaited(_prefetchQuestionPreviewUrls(questions));
      unawaited(_prefetchFigurePreviewUrls(questions));
      unawaited(_syncFigurePollingForActiveDocument());
    } catch (e) {
      _appendPipelineLog('review', '문항 갱신 실패: $e', error: true);
      _showSnack('문항 목록 갱신 실패: $e', error: true);
    }
  }

  Future<void> _saveQuestionsToServer() async {
    if (_isSavingQuestionChanges || _isDeletingCurrentQuestions) return;
    if (_dirtyQuestionIds.isEmpty && !_dirtyDocumentMeta && !_needsPublish) {
      _showSnack('업로드할 변경사항이 없습니다.');
      return;
    }
    if (_dirtyDocumentMeta && _isSchoolPastSource && _sourceExamTerm.isEmpty) {
      _showSnack('내신 기출은 중간/기말 중 하나를 선택해주세요.', error: true);
      return;
    }
    final dirtyIds = _dirtyQuestionIds.toList(growable: false);
    final doc = _activeDocument;
    final academyId = _academyId;
    final curriculumCode = _selectedCurriculumCode;
    final sourceTypeCode = _selectedSourceTypeCode;
    final courseLabel = _selectedCourseLabel;
    final gradeLabel = _sourceGradeCtrl.text.trim();
    final examYear = _sourceExamYearValue();
    final semesterLabel = _sourceSemester;
    final examTermLabel = _sourceExamTerm;
    final schoolName = _sourceSchoolCtrl.text.trim();
    final publisherName = _sourcePublisherCtrl.text.trim();
    final materialName = _sourceMaterialCtrl.text.trim();
    final classificationDetail = _buildClassificationDetailPayload();
    if (!mounted) return;
    setState(() {
      _isSavingQuestionChanges = true;
    });
    try {
      for (final id in dirtyIds) {
        final match = _questions.where((q) => q.id == id);
        if (match.isEmpty) continue;
        final q = match.first;
        final mergedMeta = Map<String, dynamic>.from(q.meta);
        final parsedScore = _parseScoreDraft(_scoreDraftFor(q));
        if (parsedScore == null) {
          mergedMeta.remove('score_point');
        } else {
          final rounded = parsedScore.roundToDouble();
          mergedMeta['score_point'] =
              rounded == parsedScore ? rounded.toInt() : parsedScore;
        }
        await _service.updateQuestionReview(
          questionId: q.id,
          isChecked: q.isChecked,
          reviewerNotes: q.reviewerNotes,
          questionType: q.questionType,
          stem: q.stem,
          choices: q.choices,
          allowObjective: q.allowObjective,
          allowSubjective: q.allowSubjective,
          objectiveChoices: q.objectiveChoices,
          objectiveAnswerKey: q.objectiveAnswerKey,
          subjectiveAnswer: q.subjectiveAnswer,
          objectiveGenerated: q.objectiveGenerated,
          equations: q.equations,
          curriculumCode: curriculumCode,
          sourceTypeCode: sourceTypeCode,
          courseLabel: courseLabel,
          gradeLabel: gradeLabel,
          examYear: examYear,
          semesterLabel: semesterLabel,
          examTermLabel: examTermLabel,
          schoolName: schoolName,
          publisherName: publisherName,
          materialName: materialName,
          classificationDetail: classificationDetail,
          meta: mergedMeta,
        );
      }
      if (doc != null) {
        final mergedDocMeta = _dirtyDocumentMeta
            ? <String, dynamic>{
                ...doc.meta,
                'source_classification': _buildSourceClassificationMeta(),
              }
            : doc.meta;
        await _service.updateDocumentMeta(
          documentId: doc.id,
          meta: mergedDocMeta,
          status: 'ready',
          curriculumCode: _dirtyDocumentMeta ? curriculumCode : null,
          sourceTypeCode: _dirtyDocumentMeta ? sourceTypeCode : null,
          courseLabel: _dirtyDocumentMeta ? courseLabel : null,
          gradeLabel: _dirtyDocumentMeta ? gradeLabel : null,
          examYear: _dirtyDocumentMeta ? examYear : null,
          semesterLabel: _dirtyDocumentMeta ? semesterLabel : null,
          examTermLabel: _dirtyDocumentMeta ? examTermLabel : null,
          schoolName: _dirtyDocumentMeta ? schoolName : null,
          publisherName: _dirtyDocumentMeta ? publisherName : null,
          materialName: _dirtyDocumentMeta ? materialName : null,
          classificationDetail:
              _dirtyDocumentMeta ? classificationDetail : null,
        );
        if (_dirtyDocumentMeta) {
          if (academyId == null || academyId.isEmpty) {
            throw Exception('academy_id를 찾을 수 없습니다.');
          }
          await _service.updateQuestionsClassificationForDocument(
            academyId: academyId,
            documentId: doc.id,
            curriculumCode: curriculumCode,
            sourceTypeCode: sourceTypeCode,
            courseLabel: courseLabel,
            gradeLabel: gradeLabel,
            examYear: examYear,
            semesterLabel: semesterLabel,
            examTermLabel: examTermLabel,
            schoolName: schoolName,
            publisherName: publisherName,
            materialName: materialName,
            classificationDetail: classificationDetail,
          );
        }
      }
      if (!mounted) return;
      setState(() {
        _dirtyQuestionIds.clear();
        _dirtyDocumentMeta = false;
        _needsPublish = false;
        _scoreDrafts.clear();
      });
      _showSnack('문항을 확정 업로드했습니다. (학습 앱 반영)');
      if (dirtyIds.isNotEmpty && academyId != null && academyId.isNotEmpty) {
        final dirtyQuestions = _questions
            .where((q) => dirtyIds.contains(q.id.trim()))
            .toList(growable: false);
        unawaited(_prefetchQuestionPreviewUrls(dirtyQuestions));
      }
      if (doc != null) {
        await _loadDocumentContext(doc.id);
      } else {
        await _reloadQuestions();
      }
    } catch (e) {
      _showSnack('업로드 저장 실패: $e', error: true);
    } finally {
      if (mounted) {
        setState(() {
          _isSavingQuestionChanges = false;
        });
      }
    }
  }

  Future<void> _deleteCurrentDocumentQuestions() async {
    if (_isDeletingCurrentQuestions || _isSavingQuestionChanges) return;
    final academyId = _academyId;
    final doc = _activeDocument;
    if (academyId == null || academyId.isEmpty || doc == null) {
      _showSnack('선택된 문서가 없습니다.', error: true);
      return;
    }
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: _panel,
            title: const Text('이번 문항 삭제', style: TextStyle(color: _text)),
            content: Text(
              '${doc.sourceFilename} 문서의 추출 문항을 모두 삭제합니다.\n'
              '이 작업은 되돌릴 수 없습니다.',
              style: const TextStyle(color: _textSub, fontSize: 13),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('취소'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFDE6A73),
                ),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('삭제'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    if (!mounted) return;
    setState(() {
      _isDeletingCurrentQuestions = true;
    });
    try {
      await _service.deleteQuestionsForDocument(
        academyId: academyId,
        documentId: doc.id,
      );
      if (!mounted) return;
      setState(() {
        _questions = <ProblemBankQuestion>[];
        _dirtyQuestionIds.clear();
        _questionPreviewUrls.clear();
        _scoreDrafts.clear();
        _hasExtracted = false;
        _needsPublish = false;
      });
      _showSnack('이번 문항을 모두 삭제했습니다.');
      await _loadDocumentContext(doc.id);
    } catch (e) {
      _showSnack('문항 삭제 실패: $e', error: true);
    } finally {
      if (mounted) {
        setState(() {
          _isDeletingCurrentQuestions = false;
        });
      }
    }
  }

  Future<void> _setAllChecked(bool checked) async {
    if (_questions.isEmpty) return;
    if (!mounted) return;
    setState(() {
      _questions = _questions
          .map((q) => q.copyWith(isChecked: checked))
          .toList(growable: false);
      _dirtyQuestionIds.addAll(_questions.map((q) => q.id));
    });
  }

  Future<void> _toggleChecked(ProblemBankQuestion q, bool value) async {
    if (!mounted) return;
    setState(() {
      _questions = _questions
          .map((e) => e.id == q.id ? e.copyWith(isChecked: value) : e)
          .toList(growable: false);
      _dirtyQuestionIds.add(q.id);
    });
  }

  bool _allowEssayOf(ProblemBankQuestion q) => q.meta['allow_essay'] == true;

  /// 카드 상단 배지 기준 유형(객관식 / 주관식 / 서술형 / 그 외).
  String _primaryTypeBucket(ProblemBankQuestion q) {
    final t = q.questionType.trim();
    if (t.contains('서술')) return '서술형';
    if (t.contains('객관식')) return '객관식';
    if (t.contains('주관식')) return '주관식';
    if (_allowEssayOf(q) && q.allowSubjective) return '서술형';
    if (q.allowObjective && !q.allowSubjective) return '객관식';
    if (q.allowSubjective && !q.allowObjective) return '주관식';
    if (q.allowSubjective && _allowEssayOf(q)) return '서술형';
    return '미분류';
  }

  /// 배지 탭: 객관식 → 주관식 → 서술형 → 객관식 (문항 유형·출제 허용 동기화).
  void _cycleQuestionTypeBadge(ProblemBankQuestion q) {
    final cur = _primaryTypeBucket(q);
    late final String nextType;
    late final bool obj;
    late final bool subj;
    late final bool essay;
    switch (cur) {
      case '객관식':
        nextType = '주관식';
        obj = false;
        subj = true;
        essay = false;
        break;
      case '주관식':
        nextType = '서술형';
        obj = false;
        subj = true;
        essay = true;
        break;
      case '서술형':
        nextType = '객관식';
        obj = true;
        subj = false;
        essay = false;
        break;
      default:
        nextType = '객관식';
        obj = true;
        subj = false;
        essay = false;
        break;
    }
    if (!mounted) return;
    setState(() {
      _questions = _questions
          .map(
            (e) => e.id == q.id
                ? e.copyWith(
                    questionType: nextType,
                    allowObjective: obj,
                    allowSubjective: subj,
                    meta: <String, dynamic>{
                      ...e.meta,
                      'allow_objective': obj,
                      'allow_subjective': subj,
                      'allow_essay': essay,
                    },
                  )
                : e,
          )
          .toList(growable: false);
      _dirtyQuestionIds.add(q.id);
    });
  }

  void _toggleCardMode(
    ProblemBankQuestion q, {
    bool? allowObjective,
    bool? allowSubjective,
    bool? allowEssay,
  }) {
    final nextObjective = allowObjective ?? q.allowObjective;
    final nextSubjective = allowSubjective ?? q.allowSubjective;
    final nextEssay = allowEssay ?? _allowEssayOf(q);
    if (!nextObjective && !nextSubjective) {
      _showSnack('객관식/주관식 중 하나 이상은 선택되어야 합니다.', error: true);
      return;
    }
    if (!mounted) return;
    setState(() {
      _questions = _questions
          .map(
            (e) => e.id == q.id
                ? e.copyWith(
                    allowObjective: nextObjective,
                    allowSubjective: nextSubjective,
                    meta: <String, dynamic>{
                      ...e.meta,
                      'allow_objective': nextObjective,
                      'allow_subjective': nextSubjective,
                      'allow_essay': nextEssay,
                    },
                  )
                : e,
          )
          .toList(growable: false);
      _dirtyQuestionIds.add(q.id);
    });
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
    bool allowObjective = question.allowObjective;
    bool allowSubjective = question.allowSubjective;
    bool allowEssay = _allowEssayOf(question);
    await showDialog<bool>(
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
                    '출제 허용 형식',
                    style: TextStyle(color: _textSub, fontSize: 12),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: StatefulBuilder(
                          builder: (context, setInnerState) {
                            return CheckboxListTile(
                              value: allowObjective,
                              dense: true,
                              activeColor: _accent,
                              contentPadding: EdgeInsets.zero,
                              title: const Text(
                                '객관식 출제 허용',
                                style: TextStyle(color: _textSub, fontSize: 12),
                              ),
                              controlAffinity: ListTileControlAffinity.leading,
                              onChanged: (v) {
                                final next = v ?? false;
                                if (!next && !allowSubjective) {
                                  _showSnack(
                                    '객관식/주관식 중 하나 이상은 허용해야 합니다.',
                                    error: true,
                                  );
                                  return;
                                }
                                setInnerState(() {
                                  allowObjective = next;
                                });
                              },
                            );
                          },
                        ),
                      ),
                      Expanded(
                        child: StatefulBuilder(
                          builder: (context, setInnerState) {
                            return CheckboxListTile(
                              value: allowSubjective,
                              dense: true,
                              activeColor: _accent,
                              contentPadding: EdgeInsets.zero,
                              title: const Text(
                                '주관식 출제 허용',
                                style: TextStyle(color: _textSub, fontSize: 12),
                              ),
                              controlAffinity: ListTileControlAffinity.leading,
                              onChanged: (v) {
                                final next = v ?? false;
                                if (!next && !allowObjective) {
                                  _showSnack(
                                    '객관식/주관식 중 하나 이상은 허용해야 합니다.',
                                    error: true,
                                  );
                                  return;
                                }
                                setInnerState(() {
                                  allowSubjective = next;
                                });
                              },
                            );
                          },
                        ),
                      ),
                      Expanded(
                        child: StatefulBuilder(
                          builder: (context, setInnerState) {
                            return CheckboxListTile(
                              value: allowEssay,
                              dense: true,
                              activeColor: _accent,
                              contentPadding: EdgeInsets.zero,
                              title: const Text(
                                '서술형 출제 허용',
                                style: TextStyle(color: _textSub, fontSize: 12),
                              ),
                              controlAffinity: ListTileControlAffinity.leading,
                              onChanged: (v) {
                                final next = v ?? false;
                                if (!next &&
                                    !allowObjective &&
                                    !allowSubjective) {
                                  _showSnack(
                                    '객관식/주관식 중 하나 이상은 허용해야 합니다.',
                                    error: true,
                                  );
                                  return;
                                }
                                setInnerState(() {
                                  allowEssay = next;
                                });
                              },
                            );
                          },
                        ),
                      ),
                    ],
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
                  if (!allowObjective && !allowSubjective) {
                    _showSnack(
                      '객관식/주관식 중 하나 이상은 허용해야 합니다.',
                      error: true,
                    );
                    return;
                  }
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
                  if (!mounted) return;
                  final updatedQ = question.copyWith(
                    isChecked: checked,
                    reviewerNotes: noteCtrl.text.trim(),
                    questionType: selectedType,
                    stem: stemCtrl.text.trim(),
                    allowObjective: allowObjective,
                    allowSubjective: allowSubjective,
                    meta: <String, dynamic>{
                      ...question.meta,
                      'allow_objective': allowObjective,
                      'allow_subjective': allowSubjective,
                      'allow_essay': allowEssay,
                    },
                    equations: updatedEquations,
                  );
                  setState(() {
                    _questions = _questions
                        .map((q) => q.id == question.id ? updatedQ : q)
                        .toList(growable: false);
                  });
                  if (context.mounted) Navigator.of(context).pop(true);
                  if (!mounted) return;
                  final previewUrl = await _saveAndRefreshPreview(updatedQ);
                  if (!mounted) return;
                  if (previewUrl != null && previewUrl.isNotEmpty) {
                    _showSnack('저장했고 문제 미리보기를 갱신했습니다.');
                  } else {
                    _showSnack(
                      '검수 내용은 저장했습니다. 미리보기가 아직 없으면 잠시 후 다시 시도하거나 상단 `업로드`를 이용하세요.',
                    );
                  }
                } catch (e) {
                  _showSnack('검수 편집 실패: $e', error: true);
                }
              },
              child: const Text('저장'),
            ),
          ],
        );
      },
    );
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
              itemHeight: null,
              menuMaxHeight: 420,
              hint: const Text(
                '업로드 문서를 선택하세요',
                style: TextStyle(color: _textSub, fontSize: 12),
              ),
              style: const TextStyle(
                color: _text,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
              selectedItemBuilder: (context) => _documents
                  .map(
                    (d) => Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        d.sourceFilename,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: _text,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  )
                  .toList(growable: false),
              items: _documents
                  .map(
                    (d) => DropdownMenuItem<String>(
                      value: d.id,
                      child: _buildRecentDocumentMenuItem(d),
                    ),
                  )
                  .toList(),
              onChanged: (value) async {
                if (value == null) return;
                final doc = _documents.firstWhere((d) => d.id == value);
                setState(() {
                  _activeDocument = doc;
                  _questions = <ProblemBankQuestion>[];
                  _dirtyQuestionIds.clear();
                  _questionPreviewUrls.clear();
                  _needsPublish = false;
                  _applySourceMetaFromDocument(doc);
                  _scoreDrafts.clear();
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

  /// 최근 문서 드롭다운 아이템: hover 시 전체 파일명 툴팁 + 우측 X 하드삭제.
  Widget _buildRecentDocumentMenuItem(ProblemBankDocument doc) {
    return Tooltip(
      message: doc.sourceFilename,
      waitDuration: const Duration(milliseconds: 350),
      preferBelow: false,
      child: Row(
        mainAxisSize: MainAxisSize.max,
        children: [
          Expanded(
            child: Text(
              doc.sourceFilename,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: const TextStyle(
                color: _text,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 6),
          InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () => unawaited(_handleRecentDocumentHardDelete(doc)),
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(
                Icons.close,
                size: 14,
                color: Color(0xFFDE6A73),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _handleRecentDocumentHardDelete(
    ProblemBankDocument doc,
  ) async {
    // 드롭다운 메뉴 닫기.
    if (mounted) {
      Navigator.of(context, rootNavigator: true).maybePop();
    }
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: _panel,
            title: const Text(
              '문서 하드삭제',
              style: TextStyle(color: _text, fontWeight: FontWeight.w800),
            ),
            content: Text(
              '"${doc.sourceFilename}" 문서와 연결된 문항/미리보기가 완전히 삭제됩니다.',
              style: const TextStyle(color: _textSub, height: 1.45),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('취소'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFDE6A73),
                  foregroundColor: Colors.white,
                ),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('삭제'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    await _hardDeleteSyncedDocument(doc);
  }

  Widget _buildPipelineMarquee() {
    final step1Done = _hasExtracted &&
        _activeDocument != null &&
        !_isUploading &&
        !_isExtracting;
    final step2Done = _checkedCount > 0;
    final step3Done = _documentDbReady;
    final step3Active = _needsPublish && !step3Done;
    final elapsed = _extractQueuedElapsed;
    final isQueuedLong =
        elapsed != null && elapsed >= const Duration(minutes: 2);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
                active:
                    !(_isUploading || _isExtracting) && !step2Done && step1Done,
                done: step2Done,
              ),
              _buildStepChip(
                index: 3,
                title: 'DB화',
                active: step3Active,
                done: step3Done,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Divider(height: 1, thickness: 1, color: _border),
          ),
          LinearProgressIndicator(
            value:
                _progressIndeterminate ? null : _progressValue.clamp(0.0, 1.0),
            minHeight: 6,
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
            '1) HWPX 업로드',
            subtitle: '업로드 직후 자동으로 추출하고, 검수 후 업로드로 확정합니다.',
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
              label: Text(_isUploading ? '업로드 중...' : 'HWPX 업로드 (자동 추출)'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: (_isUploading ||
                      _isResetting ||
                      _isExtracting ||
                      _schemaMissing ||
                      _academyMissing ||
                      _academyId == null ||
                      _academyId!.isEmpty ||
                      _activeDocument == null)
                  ? null
                  : () => unawaited(_startExtractForActiveDocument()),
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF2C8C66)),
              icon: _isExtracting
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.play_arrow_rounded, size: 18),
              label: Text(
                _isExtracting
                    ? '추출 중...'
                    : (_hasExtracted ? '재추출 시작' : '추출 다시 시작'),
              ),
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

  /// 현재 문서의 교육과정·출처·내신/모의 메타 (업로드·분류 탭 왼쪽 공통).
  Widget _buildDocumentClassificationPanel() {
    final fieldDeco = InputDecoration(
      isDense: true,
      filled: true,
      fillColor: _field,
      labelStyle: const TextStyle(color: _textSub, fontSize: 11),
      hintStyle: const TextStyle(color: _textSub, fontSize: 11),
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
    );

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
            '2) 문서 분류',
            subtitle:
                '교육과정·출처·내신/모의 정보를 입력합니다. 반영은 우측 `업로드`로 저장합니다.',
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: _buildDropdownField(
              label: '교육과정',
              value: _selectedCurriculumCode,
              values: _curriculumLabels.keys.toList(growable: false),
              displayLabels: _curriculumLabels,
              onChanged: (v) {
                setState(() {
                  _selectedCurriculumCode = v;
                });
                _markDocumentMetaDirty();
              },
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: _buildDropdownField(
              label: '출처',
              value: _selectedSourceTypeCode,
              values: _sourceTypeLabels.keys.toList(growable: false),
              displayLabels: _sourceTypeLabels,
              onChanged: (v) {
                setState(() {
                  _selectedSourceTypeCode = v;
                });
                _markDocumentMetaDirty();
              },
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: _buildDropdownField(
              label: '과정',
              value: _selectedCourseLabel,
              values: _courseLabelOptions,
              displayLabels: _courseLabelLabels,
              onChanged: (v) {
                setState(() {
                  _selectedCourseLabel = v;
                });
                _markDocumentMetaDirty();
              },
            ),
          ),
          if (_dirtyDocumentMeta) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: _accent.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _accent),
              ),
              child: const Text(
                '분류 변경사항은 우측 `업로드`로 저장하세요.',
                style: TextStyle(color: _accent, fontSize: 11.5),
              ),
            ),
          ],
          if (_isSchoolPastSource ||
              _selectedSourceTypeCode == 'mock_past') ...[
            const SizedBox(height: 10),
            TextField(
              controller: _sourceYearCtrl,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: _text, fontSize: 12.4),
              decoration: fieldDeco.copyWith(
                labelText: '년도',
                hintText: '예: 2026',
              ),
              onChanged: (_) => _markDocumentMetaDirty(),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _sourceSchoolCtrl,
              style: const TextStyle(color: _text, fontSize: 12.4),
              decoration: fieldDeco.copyWith(
                labelText: '학교명',
                hintText: '예: 경신중',
              ),
              onChanged: (_) => _markDocumentMetaDirty(),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _sourceGradeCtrl,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: _text, fontSize: 12.4),
              decoration: fieldDeco.copyWith(
                labelText: '학년',
                hintText: '예: 1',
              ),
              onChanged: (_) => _markDocumentMetaDirty(),
            ),
          ],
          if (_isSchoolPastSource) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: _buildDropdownField(
                label: '학기',
                value: _sourceSemester,
                values: const <String>['1학기', '2학기'],
                onChanged: (v) {
                  setState(() {
                    _sourceSemester = v;
                  });
                  _markDocumentMetaDirty();
                },
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: Checkbox(
                        value: _sourceExamTerm == '중간',
                        activeColor: _accent,
                        visualDensity:
                            const VisualDensity(horizontal: -4, vertical: -4),
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() {
                            _sourceExamTerm = v ? '중간' : '';
                          });
                          _markDocumentMetaDirty();
                        },
                      ),
                    ),
                    const SizedBox(width: 2),
                    const Text(
                      '중간',
                      style: TextStyle(color: _textSub, fontSize: 12),
                    ),
                  ],
                ),
                const SizedBox(width: 16),
                Row(
                  children: [
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: Checkbox(
                        value: _sourceExamTerm == '기말',
                        activeColor: _accent,
                        visualDensity:
                            const VisualDensity(horizontal: -4, vertical: -4),
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() {
                            _sourceExamTerm = v ? '기말' : '';
                          });
                          _markDocumentMetaDirty();
                        },
                      ),
                    ),
                    const SizedBox(width: 2),
                    const Text(
                      '기말',
                      style: TextStyle(color: _textSub, fontSize: 12),
                    ),
                  ],
                ),
              ],
            ),
          ],
          if (_isPrivateSource) ...[
            const SizedBox(height: 10),
            TextField(
              controller: _sourcePublisherCtrl,
              style: const TextStyle(color: _text, fontSize: 12.4),
              decoration: fieldDeco.copyWith(
                labelText: '출판사/브랜드',
                hintText: '예: 비상, 메가스터디',
              ),
              onChanged: (_) => _markDocumentMetaDirty(),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _sourceMaterialCtrl,
              style: const TextStyle(color: _text, fontSize: 12.4),
              decoration: fieldDeco.copyWith(
                labelText: '교재명',
                hintText: '예: 수학의 정석',
              ),
              onChanged: (_) => _markDocumentMetaDirty(),
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
    Map<String, String>? displayLabels,
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
                      child: Text(displayLabels?[e] ?? e),
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
        _normalizeUnicodeScriptTokens(raw.replaceAll(RegExp(r'`+'), ' '));
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
        .replaceAll(RegExp(r'\bge\b', caseSensitive: false), r'\ge ')
        .replaceAll(RegExp(r'\bRARROW\b'), r'\Rightarrow ')
        .replaceAll(RegExp(r'\bLARROW\b'), r'\Leftarrow ')
        .replaceAll(RegExp(r'\bLRARROW\b'), r'\Leftrightarrow ')
        .replaceAll(RegExp(r'\brarrow\b'), r'\rightarrow ')
        .replaceAll(RegExp(r'\blarrow\b'), r'\leftarrow ')
        .replaceAll(RegExp(r'\blrarrow\b'), r'\leftrightarrow ')
        .replaceAll(RegExp(r'\bSIM\b'), r'\sim ')
        .replaceAll(RegExp(r'\bAPPROX\b'), r'\approx ')
        .replaceAll(RegExp(r'\bDEG\b'), r'^{\circ}')
        .replaceAll(RegExp(r'\blt\b'), '< ')
        .replaceAll(RegExp(r'\bgt\b'), '> ')
        .replaceAll(RegExp(r'\bne\b', caseSensitive: false), r'\ne ');

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
    if (_containsNestedFractionExpression(latex)) return 1.94;
    if (_containsFractionExpression(latex)) return 1.82;
    return 1.60;
  }

  double _denseMathLineHeight(String raw, {double normal = 1.66}) {
    final latex = _sanitizeLatexForMathTex(raw);
    if (_containsNestedFractionExpression(latex)) return normal + 0.32;
    if (_containsFractionExpression(latex)) return normal + 0.20;
    if (RegExp(r'[A-Za-z0-9]').hasMatch(latex)) return normal + 0.06;
    return normal;
  }

  double _mathSymmetricVerticalPadding(
    String raw, {
    bool compact = false,
  }) {
    final latex = _sanitizeLatexForMathTex(raw);
    if (_containsNestedFractionExpression(latex)) {
      return compact ? 1.6 : 2.4;
    }
    if (_containsFractionExpression(latex)) {
      return compact ? 1.2 : 1.8;
    }
    return compact ? 0.25 : 0.35;
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

  String _sanitizeAnswerText(String raw) {
    return raw
        .trim()
        .replaceFirst(RegExp(r'^\[?\s*정답\s*\]?\s*[:：]?\s*'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _objectiveAnswerToSubjective(String value) {
    return value.replaceAllMapped(RegExp(r'[①②③④⑤⑥⑦⑧⑨⑩]'), (m) {
      switch (m.group(0)) {
        case '①':
          return '1';
        case '②':
          return '2';
        case '③':
          return '3';
        case '④':
          return '4';
        case '⑤':
          return '5';
        case '⑥':
          return '6';
        case '⑦':
          return '7';
        case '⑧':
          return '8';
        case '⑨':
          return '9';
        case '⑩':
          return '10';
      }
      return '';
    });
  }

  String _choiceLabelByIndex(int index) {
    const labels = <String>['①', '②', '③', '④', '⑤', '⑥', '⑦', '⑧', '⑨', '⑩'];
    if (index >= 0 && index < labels.length) return labels[index];
    return '${index + 1}';
  }

  List<ProblemBankChoice> _previewChoicesOf(ProblemBankQuestion q) {
    final source =
        q.objectiveChoices.length >= 2 ? q.objectiveChoices : q.choices;
    final out = <ProblemBankChoice>[];
    for (var i = 0; i < source.length; i += 1) {
      final text = _normalizePreviewLine(source[i].text);
      if (text.isEmpty) continue;
      final label = source[i].label.trim().isNotEmpty
          ? source[i].label.trim()
          : _choiceLabelByIndex(i);
      out.add(ProblemBankChoice(label: label, text: text));
    }
    return out;
  }

  int? _answerTokenToChoiceIndex(String token) {
    final raw = token.trim();
    if (raw.isEmpty) return null;
    const circled = <String>['①', '②', '③', '④', '⑤', '⑥', '⑦', '⑧', '⑨', '⑩'];
    final circledIdx = circled.indexOf(raw);
    if (circledIdx >= 0) return circledIdx;
    final normalized = raw.replaceAll(RegExp(r'[()（）.]'), '').trim();
    final n = int.tryParse(normalized);
    if (n != null && n >= 1) return n - 1;
    return null;
  }

  bool _looksLikeObjectiveKey(String value) {
    final normalized = _sanitizeAnswerText(value);
    if (normalized.isEmpty) return false;
    return RegExp(
      r'^(?:[①②③④⑤⑥⑦⑧⑨⑩]|[1-9]|10)(?:\s*[,/]\s*(?:[①②③④⑤⑥⑦⑧⑨⑩]|[1-9]|10))*$',
    ).hasMatch(normalized);
  }

  String _subjectiveFromObjectiveChoiceText(
    String objectiveAnswer,
    List<ProblemBankChoice> choices,
  ) {
    final normalized = _sanitizeAnswerText(objectiveAnswer);
    if (normalized.isEmpty) return '';
    final tokens = normalized
        .split(RegExp(r'\s*[,/]\s*'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    final unitTokens = tokens.isNotEmpty ? tokens : <String>[normalized];
    final converted = <String>[];
    for (final token in unitTokens) {
      final idx = _answerTokenToChoiceIndex(token);
      if (idx != null && idx >= 0 && idx < choices.length) {
        final text = _normalizePreviewLine(choices[idx].text);
        if (text.isNotEmpty) {
          converted.add(text);
          continue;
        }
      }
      converted.add(_objectiveAnswerToSubjective(token));
    }
    return _sanitizeAnswerText(converted.join(', '));
  }

  String _objectiveAnswerForPreview(ProblemBankQuestion q) {
    final raw = _sanitizeAnswerText(
      q.objectiveAnswerKey.isNotEmpty
          ? q.objectiveAnswerKey
          : '${q.meta['objective_answer_key'] ?? q.meta['answer_key'] ?? ''}',
    );
    return raw;
  }

  String _subjectiveAnswerForPreview(ProblemBankQuestion q) {
    final choices = _previewChoicesOf(q);
    final shouldMapLegacyObjective =
        q.questionType.contains('객관식') || q.choices.length >= 2;
    final direct = _sanitizeAnswerText(
      q.subjectiveAnswer.isNotEmpty
          ? q.subjectiveAnswer
          : '${q.meta['subjective_answer'] ?? ''}',
    );
    if (direct.isNotEmpty) {
      if (shouldMapLegacyObjective &&
          _looksLikeObjectiveKey(direct) &&
          choices.isNotEmpty) {
        final mapped = _subjectiveFromObjectiveChoiceText(direct, choices);
        if (mapped.isNotEmpty) return mapped;
      }
      return direct;
    }
    final objective = _objectiveAnswerForPreview(q);
    if (objective.isEmpty) return '';
    return _subjectiveFromObjectiveChoiceText(objective, choices);
  }

  bool _isObjectiveAnswerPreview(ProblemBankQuestion q, String answer) {
    final normalized = answer.trim();
    if (normalized.isEmpty) return false;
    final hasChoices = q.objectiveChoices.length >= 2 || q.choices.length >= 2;
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
    final objective = _objectiveAnswerForPreview(q);
    final subjective = _subjectiveAnswerForPreview(q);
    final objectiveText = objective.isEmpty ? '-' : objective;
    final subjectiveText = subjective.isEmpty ? '-' : subjective;
    final isObjectiveAnswer = _isObjectiveAnswerPreview(q, objectiveText);
    final lineHeight = _denseMathLineHeight(objectiveText,
        normal: isObjectiveAnswer ? 1.34 : 1.4);
    final objectiveStyle = TextStyle(
      color: const Color(0xFF232323),
      fontFamily: _previewKoreanFontFamily,
      fontSize: isObjectiveAnswer
          ? (expanded ? 14.8 : 14.4)
          : (expanded ? 13.6 : 13.2),
      height: lineHeight,
      fontWeight: FontWeight.w600,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (objectiveText == '-')
          const Text(
            '-',
            style: TextStyle(color: Color(0xFF232323), fontSize: 13.4),
          )
        else
          LatexTextRenderer(
            _toPreviewMathMarkup(objectiveText, forceMathTokenWrap: true),
            softWrap: true,
            enableDisplayMath: true,
            inlineMathScale: _previewMathScale,
            fractionInlineMathScale: _previewFractionMathScale,
            displayMathScale: _previewMathScale,
            blockVerticalPadding: lineHeight >= 1.7 ? 1.0 : 0.6,
            style: objectiveStyle,
          ),
        const SizedBox(height: 6),
        if (subjectiveText == '-')
          const Text(
            '-',
            style: TextStyle(color: Color(0xFF232323), fontSize: 13.4),
          )
        else
          _buildStemTextPreviewLine(
            subjectiveText,
            fontSize: expanded ? 13.8 : 13.4,
            normalHeight: 1.58,
          ),
      ],
    );
  }

  Widget _buildAnswerPreviewThumbnail(ProblemBankQuestion q,
      {bool expanded = false}) {
    return Container(
      height: expanded ? null : 95,
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFFFCFCFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFD5D5D5)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      child: SingleChildScrollView(
        physics: expanded
            ? const ClampingScrollPhysics()
            : const NeverScrollableScrollPhysics(),
        child: DefaultTextStyle(
          style: const TextStyle(
            color: Color(0xFF232323),
            fontFamily: _previewKoreanFontFamily,
            fontSize: 13.4,
          ),
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
    double normalHeight = 1.66,
  }) {
    final normalized = _normalizePreviewMultiline(
        text.replaceAll(_structuralMarkerRegex, ' '));
    final lineHeight = _denseMathLineHeight(normalized, normal: normalHeight);
    final verticalPad = _mathSymmetricVerticalPadding(normalized);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: verticalPad),
      child: LatexTextRenderer(
        _toPreviewMathMarkup(normalized, forceMathTokenWrap: true),
        softWrap: true,
        enableDisplayMath: true,
        inlineMathScale: _previewMathScale,
        fractionInlineMathScale: _previewFractionMathScale,
        displayMathScale: _previewMathScale,
        blockVerticalPadding: lineHeight >= 1.82 ? 1.8 : 1.0,
        style: TextStyle(
          fontSize: fontSize,
          height: lineHeight,
          color: const Color(0xFF232323),
          fontFamily: _previewKoreanFontFamily,
        ),
      ),
    );
  }

  int _figureOrderHintInOrderedAssets(
    Map<String, dynamic>? asset,
    List<Map<String, dynamic>> orderedAssets,
  ) {
    if (asset == null || orderedAssets.isEmpty) return 1;
    final targetPath = '${asset['path'] ?? ''}'.trim();
    final targetId = '${asset['id'] ?? ''}'.trim();
    final targetIndex = int.tryParse('${asset['figure_index'] ?? ''}');
    for (var i = 0; i < orderedAssets.length; i += 1) {
      final candidate = orderedAssets[i];
      final candidatePath = '${candidate['path'] ?? ''}'.trim();
      if (targetPath.isNotEmpty && candidatePath == targetPath) return i + 1;
      final candidateId = '${candidate['id'] ?? ''}'.trim();
      if (targetId.isNotEmpty && candidateId == targetId) return i + 1;
      final candidateIndex = int.tryParse('${candidate['figure_index'] ?? ''}');
      if (targetIndex != null &&
          candidateIndex != null &&
          targetIndex == candidateIndex) {
        return i + 1;
      }
    }
    return 1;
  }

  Widget _buildInlineFigureVisual(
    ProblemBankQuestion q, {
    Map<String, dynamic>? asset,
    bool expanded = false,
    required int orderHint,
  }) {
    final assetPath = '${asset?['path'] ?? ''}'.trim();
    final previewUrl = _figurePreviewUrlForPath(q.id, assetPath);
    final hasFigureAsset = asset != null;
    final figureHeight = (expanded ? 232.0 : 138.0) *
        _figureRenderScaleForAsset(
          q,
          asset: asset,
          order: orderHint,
        );
    if (previewUrl.isNotEmpty) {
      return ClipRRect(
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
                style: TextStyle(color: Color(0xFF906060), fontSize: 11.8),
              ),
            ),
          ),
        ),
      );
    }
    return Container(
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
    );
  }

  Widget _buildInlineFigureInStem(
    ProblemBankQuestion q, {
    Map<String, dynamic>? asset,
    bool expanded = false,
  }) {
    final orderedAssets = _orderedFigureAssetsOf(q);
    final effectiveAsset = asset ?? _latestFigureAssetOf(q);
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
    final figureOrderHint =
        _figureOrderHintInOrderedAssets(effectiveAsset, orderedAssets);
    final currentKey = _figureScaleKeyForAsset(effectiveAsset, figureOrderHint);
    final pairKeys = _figureHorizontalPairKeysOf(q);
    final keyToAsset = <String, Map<String, dynamic>>{};
    final keyToOrder = <String, int>{};
    for (var i = 0; i < orderedAssets.length; i += 1) {
      final item = orderedAssets[i];
      final key = _figureScaleKeyForAsset(item, i + 1);
      keyToAsset[key] = item;
      keyToOrder[key] = i + 1;
    }
    String? partnerKey;
    for (final pairKey in pairKeys) {
      final parts = _figurePairParts(pairKey);
      if (parts.length != 2) continue;
      if (parts[0] == currentKey) {
        partnerKey = parts[1];
        break;
      }
      if (parts[1] == currentKey) {
        partnerKey = parts[0];
        break;
      }
    }
    if (partnerKey != null) {
      final partnerAsset = keyToAsset[partnerKey];
      final currentOrder = keyToOrder[currentKey] ?? figureOrderHint;
      final partnerOrder = keyToOrder[partnerKey] ?? (currentOrder + 1);
      if (partnerAsset != null) {
        if (partnerOrder < currentOrder) {
          return const SizedBox.shrink();
        }
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _buildInlineFigureVisual(
                      q,
                      asset: effectiveAsset,
                      expanded: expanded,
                      orderHint: currentOrder,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildInlineFigureVisual(
                      q,
                      asset: partnerAsset,
                      expanded: expanded,
                      orderHint: partnerOrder,
                    ),
                  ),
                ],
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
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildInlineFigureVisual(
            q,
            asset: effectiveAsset,
            expanded: expanded,
            orderHint: figureOrderHint,
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
      fontFamily: _previewKoreanFontFamily,
    );
    if (itemMatch == null) {
      final verticalPad =
          _mathSymmetricVerticalPadding(normalized, compact: true);
      return Padding(
        padding: EdgeInsets.symmetric(vertical: verticalPad),
        child: LatexTextRenderer(
          _toPreviewMathMarkup(normalized, forceMathTokenWrap: true),
          softWrap: true,
          enableDisplayMath: true,
          inlineMathScale: _previewMathScale,
          fractionInlineMathScale: _previewFractionMathScale,
          displayMathScale: _previewMathScale,
          blockVerticalPadding: lineHeight >= 1.9 ? 1.2 : 0.7,
          style: style,
        ),
      );
    }
    final rawLabel = (itemMatch.group(1) ?? '').trim();
    final content = (itemMatch.group(2) ?? '').trim();
    final labelText =
        RegExp(r'^[①②③④⑤⑥⑦⑧⑨⑩]$').hasMatch(rawLabel) ? rawLabel : '$rawLabel.';
    final contentVerticalPad =
        _mathSymmetricVerticalPadding(content, compact: true);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: contentVerticalPad),
      child: Row(
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
                  _denseMathLineHeight(content, normal: 1.76) >= 1.9
                      ? 1.2
                      : 0.7,
              style: TextStyle(
                color: style.color,
                fontSize: style.fontSize,
                height: _denseMathLineHeight(content, normal: 1.76),
                fontFamily: _previewKoreanFontFamily,
              ),
            ),
          ),
        ],
      ),
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
                    fontFamily: _previewKoreanFontFamily,
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
    final symmetricPad = _mathSymmetricVerticalPadding(rendered);
    final previewText = _toPreviewMathMarkup(rendered,
        forceMathTokenWrap: true, compactFractions: true);
    const contentFontSize = 13.4;
    const labelFontSize = contentFontSize + 1.6;
    final textStyle = TextStyle(
      color: const Color(0xFF232323),
      fontSize: contentFontSize,
      height: lineHeight,
      fontFamily: _previewKoreanFontFamily,
    );
    return Padding(
      padding: EdgeInsets.symmetric(vertical: symmetricPad + 1.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            c.label,
            style: const TextStyle(
              color: Color(0xFF232323),
              fontSize: labelFontSize,
              fontWeight: FontWeight.w500,
              fontFamily: _previewKoreanFontFamily,
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

  double _estimateChoiceRequiredWidth(
      ProblemBankQuestion q, ProblemBankChoice choice) {
    final text = _normalizePreviewLine(q.renderChoiceText(choice));
    final visual = _estimateVisualLength(text);
    final latex = _sanitizeLatexForMathTex(text);
    final hasNestedFraction = _containsNestedFractionExpression(latex);
    final hasFraction = _containsFractionExpression(latex);
    final hasLongMath =
        RegExp(r'\\(sqrt|sum|int|overline|lim|log)').hasMatch(latex);
    final symbolCount = RegExp(r'[=+\-×÷<>^_]').allMatches(text).length;

    var width = 30.0 + visual * 7.4 + symbolCount * 2.6;
    if (hasFraction) width += 24.0;
    if (hasNestedFraction) width += 46.0;
    if (hasLongMath) width += 34.0;
    return width;
  }

  String _choiceLayoutMode(
    ProblemBankQuestion q,
    List<ProblemBankChoice> choices,
    double availableWidth,
  ) {
    if (choices.length != 5) return 'stacked';
    final safeWidth = availableWidth.isFinite && availableWidth > 120
        ? availableWidth
        : 620.0;
    const singleGaps = 8.0 * 4; // 5열
    const splitGaps = 8.0 * 2; // 3열
    final singleCellWidth = (safeWidth - singleGaps) / 5;
    final splitCellWidth = (safeWidth - splitGaps) / 3;
    final requiredWidths = choices
        .map((choice) => _estimateChoiceRequiredWidth(q, choice))
        .toList(growable: false);

    // 1행 우선: 실제 셀 폭에 모두 들어가면 항상 1행
    final fitsSingle = requiredWidths.every((w) => w <= singleCellWidth);
    if (fitsSingle) return 'single';

    // 2행(3+2): 각 행의 셀 폭 기준으로 들어가면 2행
    final topFits = requiredWidths.take(3).every((w) => w <= splitCellWidth);
    final bottomFits = requiredWidths.skip(3).every((w) => w <= splitCellWidth);
    if (topFits && bottomFits) return 'split_3_2';

    // 그 외는 5행으로 내려 오버플로우를 방지
    return 'stacked';
  }

  Widget _buildChoiceInlineCell(
    ProblemBankQuestion q,
    ProblemBankChoice c, {
    bool expanded = false,
  }) {
    final rendered = _normalizePreviewLine(q.renderChoiceText(c));
    final lineHeight = _choicePreviewLineHeight(rendered);
    final symmetricPad = _mathSymmetricVerticalPadding(rendered, compact: true);
    final contentFontSize = expanded ? 13.6 : 13.4;
    final labelFontSize = contentFontSize + 1.6;
    final textStyle = TextStyle(
      color: const Color(0xFF232323),
      fontSize: contentFontSize,
      height: lineHeight,
      fontFamily: _previewKoreanFontFamily,
    );
    return Padding(
      padding: EdgeInsets.symmetric(vertical: symmetricPad),
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
              fontFamily: _previewKoreanFontFamily,
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
            child: _buildChoiceInlineCell(
              q,
              rowChoices[i],
              expanded: expanded,
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
    List<ProblemBankChoice>? sourceChoices,
    double availableWidth = 620,
  }) {
    final choices = (sourceChoices ?? _previewChoicesOf(q))
        .take(expanded ? 10 : 5)
        .toList(growable: false);
    if (choices.isEmpty) return const <Widget>[];
    final mode = _choiceLayoutMode(q, choices, availableWidth);
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

  double _stemToChoiceGap({required bool expanded}) {
    // 본문 기본 줄간격(라인 높이 - 폰트 크기)을 기준으로,
    // 문제 본문과 5지선다 사이 간격을 정확히 2배로 맞춘다.
    const stemLineHeight = 1.66;
    final stemFontSize = expanded ? 13.8 : 13.4;
    final stemLineSpacing = stemFontSize * (stemLineHeight - 1.0);
    return stemLineSpacing * 2;
  }

  static const double _pdfQuestionNumberLaneWidth = 34.0;
  static const double _pdfQuestionNumberGap = 8.0;
  static const double _pdfQuestionNumberTopOffset = 2.0;

  Widget _buildPdfQuestionNumberLabel(
    ProblemBankQuestion q, {
    bool expanded = false,
  }) {
    final number =
        q.questionNumber.trim().isEmpty ? '?' : q.questionNumber.trim();
    return Text(
      '$number.',
      style: TextStyle(
        color: const Color(0xFF232323),
        fontSize: (expanded ? 13.8 : 13.4) + 1.0,
        fontWeight: FontWeight.w600,
        height: 1.58,
        fontFamily: _previewKoreanFontFamily,
      ),
    );
  }

  /// 서버 썸네일 이미지 실패 시 로컬 텍스트·수식 미리보기 폴백.
  Widget _buildPdfPreviewPaperContent(
    ProblemBankQuestion q, {
    bool expanded = false,
    bool scrollable = true,
    bool bordered = true,
    bool shadow = true,
    bool showQuestionNumberPrefix = false,
    EdgeInsetsGeometry contentPadding =
        const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
  }) {
    final stemPreview = _stemPreviewWithMarkers(q);
    final viewBlockLines = _viewBlockPreviewLines(q, max: expanded ? 18 : 6);
    final stemBlocks =
        _buildStemPreviewBlocks(q, stemPreview, expanded: expanded);
    final previewChoices = _previewChoicesOf(q);
    final body = LayoutBuilder(
      builder: (context, constraints) {
        final numberingInset = showQuestionNumberPrefix
            ? (_pdfQuestionNumberLaneWidth + _pdfQuestionNumberGap)
            : 0.0;
        final choiceAvailableWidth =
            math.max(120.0, constraints.maxWidth - numberingInset);
        final contentChildren = <Widget>[
          ...stemBlocks,
          if (viewBlockLines.isNotEmpty) ...[
            _buildViewBlockPanel(
              viewBlockLines.take(expanded ? 18 : 6).toList(growable: false),
              expanded: expanded,
            ),
          ],
          if (previewChoices.isNotEmpty) ...[
            SizedBox(height: _stemToChoiceGap(expanded: expanded)),
            ..._buildChoicePreviewBlocks(
              q,
              expanded: expanded,
              sourceChoices: previewChoices,
              availableWidth: choiceAvailableWidth,
            ),
          ],
        ];
        Widget questionContent = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: contentChildren,
        );
        if (showQuestionNumberPrefix) {
          questionContent = Stack(
            clipBehavior: Clip.none,
            children: [
              Padding(
                padding: EdgeInsets.only(left: numberingInset),
                child: questionContent,
              ),
              Positioned(
                left: 0,
                top: _pdfQuestionNumberTopOffset,
                width: _pdfQuestionNumberLaneWidth,
                child: Align(
                  alignment: Alignment.topRight,
                  child: _buildPdfQuestionNumberLabel(q, expanded: expanded),
                ),
              ),
            ],
          );
        }
        return DefaultTextStyle(
          style: const TextStyle(
            color: Color(0xFF232323),
            fontSize: 13.4,
            height: 1.46,
            fontFamily: _previewKoreanFontFamily,
          ),
          child: questionContent,
        );
      },
    );
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(bordered ? 6 : 0),
        border: bordered
            ? Border.all(color: const Color(0xFFD5D5D5))
            : Border.all(color: Colors.transparent),
        boxShadow: shadow
            ? const [
                BoxShadow(
                  color: Color(0x1A000000),
                  blurRadius: 3,
                  offset: Offset(0, 1),
                ),
              ]
            : null,
      ),
      padding: contentPadding,
      child: scrollable
          ? SingleChildScrollView(
              physics: const ClampingScrollPhysics(),
              child: body,
            )
          : body,
    );
  }

  /// 그리드 문항카드 등: 미리보기가 이미지·본문 높이만큼만 쓰도록 상한.
  static const double _kPdfPreviewCompactMaxHeight = 200;

  Widget _buildServerPdfPreviewThumbnail(
    ProblemBankQuestion q, {
    required String previewUrl,
    bool expanded = false,
    double? fixedHeight,
    bool compact = false,
  }) {
    final double? outerHeight = expanded
        ? null
        : (compact
            ? null
            : (fixedHeight ?? 260));
    final BoxConstraints? innerConstraints = (!expanded && compact)
        ? const BoxConstraints(maxHeight: _kPdfPreviewCompactMaxHeight)
        : null;

    Widget previewCore(BoxConstraints constraints) {
      final width =
          constraints.maxWidth.isFinite ? constraints.maxWidth : 420.0;
      final fillCompact = compact && !expanded;
      Widget netImage() {
        return Image.network(
          previewUrl,
          width: width,
          fit: fillCompact ? BoxFit.cover : BoxFit.fitWidth,
          alignment: Alignment.topCenter,
          errorBuilder: (_, __, ___) => _buildPreviewPlaceholder(
            expanded: expanded,
            fixedHeight: fixedHeight,
            compact: compact,
            message: '서버 PDF 썸네일 로드 실패',
            showSpinner: false,
          ),
        );
      }

      final scrollChild = netImage();
      if (innerConstraints != null) {
        if (fillCompact) {
          return ConstrainedBox(
            constraints: innerConstraints,
            child: SizedBox(
              width: double.infinity,
              child: scrollChild,
            ),
          );
        }
        return ConstrainedBox(
          constraints: innerConstraints,
          child: ListView(
            shrinkWrap: true,
            physics: const ClampingScrollPhysics(),
            padding: EdgeInsets.zero,
            children: [scrollChild],
          ),
        );
      }
      return SingleChildScrollView(
        physics: const ClampingScrollPhysics(),
        child: scrollChild,
      );
    }

    final previewBody = LayoutBuilder(
      builder: (context, constraints) => previewCore(constraints),
    );

    if (compact && !expanded) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: previewBody,
      );
    }

    return Container(
      height: outerHeight,
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF0E1518),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _border),
      ),
      padding: const EdgeInsets.all(8.5),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
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
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        child: previewBody,
      ),
    );
  }

  Widget _buildPreviewPlaceholder({
    bool expanded = false,
    double? fixedHeight,
    String message = '서버 미리보기 로딩 중...',
    bool showSpinner = true,
    bool compact = false,
  }) {
    final double? h = expanded
        ? null
        : (compact ? null : (fixedHeight ?? 260));
    final placeholderInner = Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showSpinner) ...[
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Color(0xFF6E7E96),
              ),
            ),
            const SizedBox(height: 10),
          ],
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              message,
              style: const TextStyle(
                color: Color(0xFF6E7E96),
                fontSize: 12,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );

    if (compact && !expanded) {
      return Container(
        width: double.infinity,
        constraints: BoxConstraints(
          minHeight: 56,
          maxHeight: _kPdfPreviewCompactMaxHeight + 24,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: ColoredBox(
            color: const Color(0xFF151C21),
            child: placeholderInner,
          ),
        ),
      );
    }

    return Container(
      height: h,
      width: double.infinity,
      constraints: expanded
          ? const BoxConstraints(minHeight: 120)
          : null,
      decoration: BoxDecoration(
        color: const Color(0xFF0E1518),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _border),
      ),
      padding: const EdgeInsets.all(8.5),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFFD5D5D5)),
        ),
        padding: const EdgeInsets.all(16),
        child: placeholderInner,
      ),
    );
  }

  Widget _buildPdfPreviewThumbnail(
    ProblemBankQuestion q, {
    bool expanded = false,
    double? fixedHeight,
    bool compact = false,
  }) {
    final questionId = q.id.trim();
    final dirty = _dirtyQuestionIds.contains(questionId);
    final status =
        (_questionPreviewStatus[questionId] ?? '').trim().toLowerCase();
    final previewError = (_questionPreviewErrors[questionId] ?? '').trim();
    final serverPreviewUrl =
        dirty ? '' : (_questionPreviewUrls[questionId] ?? '').trim();
    if (serverPreviewUrl.isNotEmpty) {
      return _buildServerPdfPreviewThumbnail(
        q,
        previewUrl: serverPreviewUrl,
        expanded: expanded,
        fixedHeight: fixedHeight,
        compact: compact,
      );
    }
    if (dirty) {
      return _buildPreviewPlaceholder(
        expanded: expanded,
        fixedHeight: fixedHeight,
        message: '변경사항이 있습니다.\n업로드 후 미리보기가 갱신됩니다.',
        showSpinner: false,
        compact: compact,
      );
    }
    if (status == 'failed' || status == 'cancelled') {
      return _buildPreviewPlaceholder(
        expanded: expanded,
        fixedHeight: fixedHeight,
        compact: compact,
        message: previewError.isNotEmpty
            ? previewError
            : '서버 PDF 미리보기에 실패했습니다.\n탭해서 다시 시도하세요.',
        showSpinner: false,
      );
    }
    if (status == 'queued' || status == 'running') {
      return _buildPreviewPlaceholder(
        expanded: expanded,
        fixedHeight: fixedHeight,
        compact: compact,
        message: '서버 PDF 미리보기 생성 중...',
      );
    }
    if (status == 'completed') {
      return _buildPreviewPlaceholder(
        expanded: expanded,
        fixedHeight: fixedHeight,
        compact: compact,
        message: '미리보기 생성 완료 (썸네일 없음)',
        showSpinner: false,
      );
    }
    return _buildPreviewPlaceholder(
      expanded: expanded,
      fixedHeight: fixedHeight,
      compact: compact,
    );
  }

  double _previewDialogWidth(ProblemBankQuestion q, Size screenSize) {
    final previewChoices = _previewChoicesOf(q);
    final totalChars = _normalizePreviewLine(q.renderedStem).length +
        previewChoices.fold<int>(
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
    final previewChoices = _previewChoicesOf(q);
    final totalChars = _normalizePreviewLine(q.renderedStem).length +
        previewChoices.fold<int>(
            0,
            (sum, c) =>
                sum + _normalizePreviewLine(q.renderChoiceText(c)).length);
    final preferred =
        (420 + totalChars * 0.42).clamp(420.0, screenSize.height * 0.9);
    return preferred.toDouble();
  }

  Map<String, dynamic> _buildDraftMeta(
    ProblemBankQuestion q,
    Map<String, double> draftMap,
    Set<String> selectedPairKeys, {
    Map<String, String>? positionMap,
  }) {
    final updatedMeta = Map<String, dynamic>.from(q.meta);

    final items = <Map<String, dynamic>>[];
    for (final e in draftMap.entries) {
      final key = e.key.trim();
      if (key.isEmpty) continue;
      final wEm = e.value.clamp(_figureWidthEmMin, _figureWidthEmMax);
      final pos = positionMap?[key] ?? 'below-stem';
      items.add(<String, dynamic>{
        'assetKey': key,
        'widthEm': (wEm * 10).roundToDouble() / 10.0,
        'position': pos,
        'anchor': 'center',
        'offsetXEm': 0,
        'offsetYEm': 0,
      });
    }
    final groups = <Map<String, dynamic>>[];
    for (final pairKey in selectedPairKeys) {
      final parts = _figurePairParts(pairKey);
      if (parts.length != 2) continue;
      groups.add(<String, dynamic>{
        'type': 'horizontal',
        'members': parts,
        'gap': 0.5,
      });
    }
    if (items.isNotEmpty) {
      updatedMeta['figure_layout'] = <String, dynamic>{
        'version': 1,
        'items': items,
        'groups': groups,
      };
    } else {
      updatedMeta.remove('figure_layout');
    }

    final legacyScaleMap = <String, dynamic>{};
    for (final e in draftMap.entries) {
      final key = e.key.trim();
      if (key.isEmpty) continue;
      final scale = _widthEmToScale(e.value);
      if ((scale - 1.0).abs() < 0.01) continue;
      legacyScaleMap[key] = (scale * 100).roundToDouble() / 100.0;
    }
    if (legacyScaleMap.isEmpty) {
      updatedMeta.remove('figure_render_scales');
    } else {
      updatedMeta['figure_render_scales'] = legacyScaleMap;
    }
    final cleanedPairPayload = selectedPairKeys
        .map((pairKey) => _figurePairParts(pairKey))
        .where((parts) => parts.length == 2)
        .map((parts) => <String, String>{'a': parts[0], 'b': parts[1]})
        .toList(growable: false);
    if (cleanedPairPayload.isEmpty) {
      updatedMeta.remove('figure_horizontal_pairs');
    } else {
      updatedMeta['figure_horizontal_pairs'] = cleanedPairPayload;
    }
    final avgScale = draftMap.isEmpty
        ? 1.0
        : draftMap.values
                .map((w) => _widthEmToScale(w))
                .fold<double>(0.0, (sum, v) => sum + v) /
            draftMap.length;
    final normalizedGlobal = _normalizeFigureScale(avgScale);
    if ((normalizedGlobal - 1.0).abs() < 0.01) {
      updatedMeta.remove('figure_render_scale');
    } else {
      updatedMeta['figure_render_scale'] =
          (normalizedGlobal * 100).roundToDouble() / 100.0;
    }
    return updatedMeta;
  }

  Future<void> _openPreviewZoomDialog(ProblemBankQuestion q) async {
    if (!mounted) return;
    final screen = MediaQuery.sizeOf(context);
    final hasFigures = q.figureRefs.isNotEmpty;
    final dialogWidth = _previewDialogWidth(q, screen);
    final baseHeight = _previewDialogHeight(q, screen);
    final dialogHeight =
        hasFigures ? (baseHeight + 180).clamp(500.0, screen.height - 40) : baseHeight;

    final figureData = hasFigures ? _prepareFigureScaleData(q) : null;
    final draftMap = figureData?.draftMap;
    final positionMap = figureData?.positionMap;
    final selectedPairKeys = figureData?.selectedPairKeys;
    var refreshing = false;
    final existingUrl =
        (_questionPreviewUrls[q.id.trim()] ?? '').trim();
    String? serverPreviewUrl =
        existingUrl.isNotEmpty ? existingUrl : null;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogContext, setLocalState) {
            final draftMeta = (hasFigures && draftMap != null && selectedPairKeys != null)
                ? _buildDraftMeta(q, draftMap, selectedPairKeys,
                    positionMap: positionMap)
                : q.meta;
            final previewQ = hasFigures ? q.copyWith(meta: draftMeta) : q;

            void applyAndRefresh() {
              if (draftMap == null || positionMap == null || selectedPairKeys == null) return;
              _setFigureRenderScales(
                q,
                Map<String, double>.from(draftMap),
                positionMap: Map<String, String>.from(positionMap),
                horizontalPairKeys: selectedPairKeys,
              );
              setLocalState(() {
                refreshing = true;
              });
              () async {
                final updatedQ = _questions
                    .where((item) => item.id == q.id)
                    .firstOrNull;
                if (updatedQ != null) {
                  final url = await _saveAndRefreshPreview(updatedQ);
                  if (url != null) {
                    serverPreviewUrl = url;
                  }
                }
                if (ctx.mounted) {
                  setLocalState(() {
                    refreshing = false;
                  });
                }
              }();
            }

            return Dialog(
              backgroundColor: _panel,
              insetPadding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: dialogWidth,
                  maxHeight: dialogHeight.toDouble(),
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
                          if (refreshing)
                            const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 8),
                              child: SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: _accent,
                                ),
                              ),
                            ),
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
                              if (serverPreviewUrl != null &&
                                  serverPreviewUrl!.isNotEmpty)
                                _buildServerPdfPreviewThumbnail(
                                  previewQ,
                                  previewUrl: serverPreviewUrl!,
                                  expanded: true,
                                )
                              else
                                _buildPreviewPlaceholder(
                                  expanded: true,
                                  message: refreshing
                                      ? '서버 미리보기 갱신 중...'
                                      : '서버 미리보기가 없습니다.\n그림 크기를 조정하면 자동으로 반영됩니다.',
                                  showSpinner: refreshing,
                                ),
                              const SizedBox(height: 10),
                              _buildAnswerPreviewThumbnail(q, expanded: true),
                              if (hasFigures) ...[
                                const SizedBox(height: 10),
                                _buildFigurePreviewThumbnail(previewQ, expanded: true),
                                const SizedBox(height: 14),
                                Container(
                                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                                  decoration: BoxDecoration(
                                    color: _field,
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(color: _border),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          const Icon(Icons.tune, color: _textSub, size: 15),
                                          const SizedBox(width: 6),
                                          const Text(
                                            '그림 크기 / 배치',
                                            style: TextStyle(
                                              color: _text,
                                              fontSize: 12.6,
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                          const Spacer(),
                                          TextButton(
                                            onPressed: () {
                                              setLocalState(() {
                                                for (final key in draftMap!.keys) {
                                                  draftMap[key] = _figureWidthEmDefault;
                                                }
                                                if (positionMap != null) {
                                                  for (final key in positionMap.keys) {
                                                    positionMap[key] = 'below-stem';
                                                  }
                                                }
                                                selectedPairKeys!.clear();
                                              });
                                              applyAndRefresh();
                                            },
                                            child: const Text(
                                              '기본값',
                                              style: TextStyle(fontSize: 11.4),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      ..._buildFigureScaleSliders(
                                        draftMap: draftMap!,
                                        positionMap: positionMap!,
                                        labels: figureData!.labels,
                                        previewUrls: figureData.previewUrls,
                                        setLocalState: setLocalState,
                                        showPreviewImages: false,
                                        onSettingChanged: applyAndRefresh,
                                      ),
                                      _buildHorizontalPairChips(
                                        candidatePairKeys: figureData.candidatePairKeys,
                                        candidatePairLabels:
                                            figureData.candidatePairLabels,
                                        selectedPairKeys: selectedPairKeys!,
                                        setLocalState: setLocalState,
                                        onSettingChanged: applyAndRefresh,
                                      ),
                                    ],
                                  ),
                                ),
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

  ({
    Map<String, double> draftMap,
    Map<String, String> positionMap,
    Map<String, String> labels,
    Map<String, String> previewUrls,
    List<String> candidatePairKeys,
    Map<String, String> candidatePairLabels,
    Set<String> selectedPairKeys,
  }) _prepareFigureScaleData(ProblemBankQuestion q) {
    final assets = _orderedFigureAssetsOf(q);
    final fallbackCount =
        assets.isNotEmpty ? assets.length : math.max(1, q.figureRefs.length);

    final existingLayout = _parseFigureLayout(q);
    final scaleMap = _figureRenderScaleMapOf(q);
    final draftMap = <String, double>{};
    final positionMap = <String, String>{};
    final labels = <String, String>{};
    final previewUrls = <String, String>{};

    for (var i = 0; i < fallbackCount; i += 1) {
      final asset = i < assets.length
          ? assets[i]
          : <String, dynamic>{'figure_index': i + 1};
      final key = _figureScaleKeyForAsset(asset, i + 1);
      final label = _figureScaleKeyLabel(key, i + 1);
      final path = '${asset['path'] ?? ''}'.trim();
      final previewUrl = _figurePreviewUrlForPath(q.id, path);

      if (existingLayout != null) {
        final layoutItem = (existingLayout['items'] as List?)
            ?.cast<Map<String, dynamic>>()
            .where((it) => it['assetKey'] == key)
            .firstOrNull;
        if (layoutItem != null) {
          draftMap[key] = (layoutItem['widthEm'] as num?)?.toDouble() ??
              _figureWidthEmDefault;
          positionMap[key] =
              '${layoutItem['position'] ?? 'below-stem'}'.trim();
        } else {
          final scale = scaleMap[key] ??
              _figureRenderScaleForAsset(q, asset: asset, order: i + 1);
          draftMap[key] = _scaleToWidthEm(scale);
          positionMap[key] = 'below-stem';
        }
      } else {
        final scale = scaleMap[key] ??
            _figureRenderScaleForAsset(q, asset: asset, order: i + 1);
        draftMap[key] = _scaleToWidthEm(scale);
        positionMap[key] = 'below-stem';
      }
      labels[key] = label;
      previewUrls[key] = previewUrl;
    }
    final availableFigureKeys = draftMap.keys.toList(growable: false);
    final candidatePairKeys = <String>[];
    final candidatePairLabels = <String, String>{};
    for (var i = 0; i < availableFigureKeys.length; i += 1) {
      for (var j = i + 1; j < availableFigureKeys.length; j += 1) {
        final pairKey =
            _figurePairKey(availableFigureKeys[i], availableFigureKeys[j]);
        if (pairKey.isEmpty) continue;
        candidatePairKeys.add(pairKey);
        final left = labels[availableFigureKeys[i]] ?? '그림 ${i + 1}';
        final right = labels[availableFigureKeys[j]] ?? '그림 ${j + 1}';
        candidatePairLabels[pairKey] = '$left + $right';
      }
    }

    Set<String> selectedPairKeys;
    if (existingLayout != null) {
      final groups = (existingLayout['groups'] as List?)
              ?.cast<Map<String, dynamic>>() ??
          const <Map<String, dynamic>>[];
      selectedPairKeys = <String>{};
      for (final g in groups) {
        if (g['type'] != 'horizontal') continue;
        final members = (g['members'] as List?)?.cast<String>() ?? const <String>[];
        for (var i = 0; i < members.length; i += 1) {
          for (var j = i + 1; j < members.length; j += 1) {
            final pk = _figurePairKey(members[i], members[j]);
            if (pk.isNotEmpty) selectedPairKeys.add(pk);
          }
        }
      }
    } else {
      selectedPairKeys = _figureHorizontalPairKeysOf(q).where((pairKey) {
        final parts = _figurePairParts(pairKey);
        if (parts.length != 2) return false;
        return draftMap.containsKey(parts[0]) &&
            draftMap.containsKey(parts[1]);
      }).toSet();
    }

    return (
      draftMap: draftMap,
      positionMap: positionMap,
      labels: labels,
      previewUrls: previewUrls,
      candidatePairKeys: candidatePairKeys,
      candidatePairLabels: candidatePairLabels,
      selectedPairKeys: selectedPairKeys,
    );
  }

  Map<String, dynamic>? _parseFigureLayout(ProblemBankQuestion q) {
    final raw = q.meta['figure_layout'];
    if (raw is! Map) return null;
    final items = raw['items'];
    if (items is! List || items.isEmpty) return null;
    return Map<String, dynamic>.from(raw.map((k, v) => MapEntry('$k', v)));
  }

  List<Widget> _buildFigureScaleSliders({
    required Map<String, double> draftMap,
    required Map<String, String> positionMap,
    required Map<String, String> labels,
    required Map<String, String> previewUrls,
    required void Function(void Function()) setLocalState,
    bool showPreviewImages = true,
    VoidCallback? onSettingChanged,
  }) {
    return [
      for (var i = 0; i < draftMap.length; i += 1)
        () {
          final key = draftMap.keys.elementAt(i);
          final widthEm = draftMap[key] ?? _figureWidthEmDefault;
          final label = labels[key] ?? '그림 ${i + 1}';
          final position = positionMap[key] ?? 'below-stem';
          final previewUrl = previewUrls[key] ?? '';
          return Container(
            margin:
                EdgeInsets.only(bottom: i == draftMap.length - 1 ? 0 : 10),
            padding: const EdgeInsets.fromLTRB(10, 9, 10, 7),
            decoration: BoxDecoration(
              color: _field,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '$label 너비',
                      style: const TextStyle(
                        color: _textSub,
                        fontSize: 12.1,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${widthEm.toStringAsFixed(1)}em',
                      style: const TextStyle(
                        color: _text,
                        fontSize: 12.1,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                if (showPreviewImages && previewUrl.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.network(
                      previewUrl,
                      height: 74,
                      width: double.infinity,
                      fit: BoxFit.contain,
                    ),
                  ),
                ],
                Slider(
                  value: widthEm.clamp(_figureWidthEmMin, _figureWidthEmMax),
                  min: _figureWidthEmMin,
                  max: _figureWidthEmMax,
                  divisions: 50,
                  activeColor: _accent,
                  onChanged: (v) {
                    setLocalState(() {
                      draftMap[key] =
                          (v * 10).roundToDouble() / 10.0;
                    });
                  },
                  onChangeEnd: (_) => onSettingChanged?.call(),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Text(
                      '위치',
                      style: TextStyle(
                        color: _textSub,
                        fontSize: 11.4,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButton<String>(
                        value: _figurePositionOptions.contains(position)
                            ? position
                            : 'below-stem',
                        isExpanded: true,
                        isDense: true,
                        style: const TextStyle(
                          color: _text,
                          fontSize: 11.4,
                        ),
                        underline: const SizedBox.shrink(),
                        items: _figurePositionOptions
                            .map((pos) => DropdownMenuItem<String>(
                                  value: pos,
                                  child: Text(
                                    _figurePositionLabels[pos] ?? pos,
                                  ),
                                ))
                            .toList(growable: false),
                        onChanged: (v) {
                          if (v == null) return;
                          setLocalState(() {
                            positionMap[key] = v;
                          });
                          onSettingChanged?.call();
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        }(),
    ];
  }

  Widget _buildHorizontalPairChips({
    required List<String> candidatePairKeys,
    required Map<String, String> candidatePairLabels,
    required Set<String> selectedPairKeys,
    required void Function(void Function()) setLocalState,
    VoidCallback? onSettingChanged,
  }) {
    if (candidatePairKeys.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        const Text(
          '가로 묶음 (선택한 두 그림을 한 줄에 배치)',
          style: TextStyle(
            color: _textSub,
            fontSize: 11.6,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final pairKey in candidatePairKeys)
              FilterChip(
                label: Text(
                  candidatePairLabels[pairKey] ?? pairKey,
                  style: const TextStyle(fontSize: 11),
                ),
                selected: selectedPairKeys.contains(pairKey),
                onSelected: (selected) {
                  setLocalState(() {
                    final parts = _figurePairParts(pairKey);
                    if (parts.length != 2) return;
                    final a = parts[0];
                    final b = parts[1];
                    if (!selected) {
                      selectedPairKeys.remove(pairKey);
                    } else {
                      selectedPairKeys.removeWhere((existing) {
                        final p = _figurePairParts(existing);
                        if (p.length != 2) return false;
                        return p[0] == a ||
                            p[0] == b ||
                            p[1] == a ||
                            p[1] == b;
                      });
                      selectedPairKeys.add(pairKey);
                    }
                  });
                  onSettingChanged?.call();
                },
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _openFigureScaleDialog(ProblemBankQuestion q) async {
    final data = _prepareFigureScaleData(q);
    final draftMap = data.draftMap;
    final positionMap = data.positionMap;
    final selectedPairKeys = data.selectedPairKeys;

    final result = await showDialog<Map<String, double>>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setLocalState) {
            return AlertDialog(
              backgroundColor: _panel,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: _border),
              ),
              title: Text(
                '${q.questionNumber}번 그림 크기 / 위치 조절',
                style: const TextStyle(color: _text, fontSize: 15.5),
              ),
              content: SizedBox(
                width: 520,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 440),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ..._buildFigureScaleSliders(
                          draftMap: draftMap,
                          positionMap: positionMap,
                          labels: data.labels,
                          previewUrls: data.previewUrls,
                          setLocalState: setLocalState,
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          '너비(em)는 글자 크기 기준 상대값입니다. 글자 크기가 변해도 비율이 유지됩니다.',
                          style: TextStyle(
                            color: _textSub,
                            fontSize: 11.2,
                            height: 1.4,
                          ),
                        ),
                        _buildHorizontalPairChips(
                          candidatePairKeys: data.candidatePairKeys,
                          candidatePairLabels: data.candidatePairLabels,
                          selectedPairKeys: selectedPairKeys,
                          setLocalState: setLocalState,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('취소'),
                ),
                TextButton(
                  onPressed: () {
                    setLocalState(() {
                      for (final key in draftMap.keys) {
                        draftMap[key] = _figureWidthEmDefault;
                      }
                      for (final key in positionMap.keys) {
                        positionMap[key] = 'below-stem';
                      }
                      selectedPairKeys.clear();
                    });
                  },
                  child: const Text('기본값'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: _accent),
                  onPressed: () =>
                      Navigator.of(ctx).pop(Map<String, double>.from(draftMap)),
                  child: const Text('적용'),
                ),
              ],
            );
          },
        );
      },
    );
    if (result == null) return;
    _setFigureRenderScales(
      q,
      result,
      positionMap: Map<String, String>.from(positionMap),
      horizontalPairKeys: selectedPairKeys,
    );
  }

  Future<void> _openAnswerReviewDialog(ProblemBankQuestion question) async {
    final objectiveCtrl =
        TextEditingController(text: _objectiveAnswerForPreview(question));
    final subjectiveCtrl =
        TextEditingController(text: _subjectiveAnswerForPreview(question));
    await showDialog<bool>(
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
                  '객관식 정답',
                  style: TextStyle(color: _textSub, fontSize: 12),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: objectiveCtrl,
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
                const SizedBox(height: 10),
                const Text(
                  '주관식 정답',
                  style: TextStyle(color: _textSub, fontSize: 12),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: subjectiveCtrl,
                  maxLines: 2,
                  style: const TextStyle(color: _text, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: '예: 2 또는 x=3',
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
                  '비워두고 저장하면 해당 정답 값을 비웁니다.',
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
                  final objectiveAnswer =
                      _sanitizeAnswerText(objectiveCtrl.text);
                  final subjectiveAnswer =
                      _sanitizeAnswerText(subjectiveCtrl.text);
                  final updatedMeta = Map<String, dynamic>.from(question.meta);
                  if (objectiveAnswer.isEmpty) {
                    updatedMeta.remove('objective_answer_key');
                  } else {
                    updatedMeta['objective_answer_key'] = objectiveAnswer;
                  }
                  if (subjectiveAnswer.isEmpty) {
                    updatedMeta.remove('subjective_answer');
                  } else {
                    updatedMeta['subjective_answer'] = subjectiveAnswer;
                  }
                  final legacyAnswer = objectiveAnswer.isNotEmpty
                      ? objectiveAnswer
                      : subjectiveAnswer;
                  if (legacyAnswer.isEmpty) {
                    updatedMeta.remove('answer_key');
                  } else {
                    updatedMeta['answer_key'] = legacyAnswer;
                  }
                  if (!mounted) return;
                  final updatedQ = question.copyWith(
                    meta: updatedMeta,
                    objectiveAnswerKey: objectiveAnswer,
                    subjectiveAnswer: subjectiveAnswer,
                  );
                  setState(() {
                    _questions = _questions
                        .map(
                          (q) => q.id == question.id ? updatedQ : q,
                        )
                        .toList(growable: false);
                  });
                  if (context.mounted) Navigator.of(context).pop(true);
                  if (!mounted) return;
                  final previewUrl = await _saveAndRefreshPreview(updatedQ);
                  if (!mounted) return;
                  if (previewUrl != null && previewUrl.isNotEmpty) {
                    _showSnack('저장했고 정답 미리보기를 갱신했습니다.');
                  } else {
                    _showSnack(
                      '정답은 저장했습니다. 미리보기가 아직 없으면 잠시 후 다시 시도하거나 상단 `업로드`를 이용하세요.',
                    );
                  }
                } catch (e) {
                  _showSnack('정답 편집 실패: $e', error: true);
                }
              },
              child: const Text('저장'),
            ),
          ],
        );
      },
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
    final latestFigureAsset = _latestFigureAssetOf(q);
    final figureApproved = _isFigureAssetApproved(latestFigureAsset);
    final figureGenerating = _figureGenerating.contains(q.id);
    final figureAssets = _orderedFigureAssetsOf(q);
    final hasMultiFigure = figureAssets.length >= 2 || q.figureRefs.length >= 2;
    final figureScaleButtonLabel =
        hasMultiFigure ? '그림별 크기' : '크기 ${_figureRenderScaleLabel(q)}';
    final scoreDraft = _scoreDraftFor(q);
    final previewChoices = _previewChoicesOf(q);
    final objectiveChoiceCount = previewChoices.length;
    final isReextractingThisQuestion = _reextractingQuestionIds.contains(q.id);
    final canReextractThisQuestion = !isReextractingThisQuestion &&
        !_isResetting &&
        !_isUploading &&
        !_isExtracting &&
        !_isSavingQuestionChanges &&
        !_isDeletingCurrentQuestions;
    final metaFooter =
        'p.${q.sourcePage}'
        ' · 보기 $objectiveChoiceCount개'
        ' · 수식 ${q.equations.length}개'
        '${isViewBlock ? ' · 보기형' : ''}'
        '${q.figureRefs.isNotEmpty ? ' · 그림 포함' : ''}';

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
      decoration: BoxDecoration(
        color: _field,
        borderRadius: BorderRadius.circular(10),
        border:
            Border.all(color: _isLowConfidence(q) ? confidenceColor : _border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
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
              Tooltip(
                message: '탭하여 유형 순환: 객관식 → 주관식 → 서술형',
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => _cycleQuestionTypeBadge(q),
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
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
                  ),
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
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 0,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          height: 20,
                          width: 20,
                          child: Checkbox(
                            value: q.allowObjective,
                            activeColor: _accent,
                            visualDensity: const VisualDensity(
                                horizontal: -4, vertical: -4),
                            onChanged: (v) {
                              if (v == null) return;
                              _toggleCardMode(q, allowObjective: v);
                            },
                          ),
                        ),
                        const SizedBox(width: 2),
                        const Text(
                          '객관식',
                          style:
                              TextStyle(color: _textSub, fontSize: 11.4),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          height: 20,
                          width: 20,
                          child: Checkbox(
                            value: q.allowSubjective,
                            activeColor: _accent,
                            visualDensity: const VisualDensity(
                                horizontal: -4, vertical: -4),
                            onChanged: (v) {
                              if (v == null) return;
                              _toggleCardMode(q, allowSubjective: v);
                            },
                          ),
                        ),
                        const SizedBox(width: 2),
                        const Text(
                          '주관식',
                          style:
                              TextStyle(color: _textSub, fontSize: 11.4),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          height: 20,
                          width: 20,
                          child: Checkbox(
                            value: _allowEssayOf(q),
                            activeColor: _accent,
                            visualDensity: const VisualDensity(
                                horizontal: -4, vertical: -4),
                            onChanged: (v) {
                              if (v == null) return;
                              _toggleCardMode(q, allowEssay: v);
                            },
                          ),
                        ),
                        const SizedBox(width: 2),
                        const Text(
                          '서술형',
                          style:
                              TextStyle(color: _textSub, fontSize: 11.4),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '배점',
                    style: TextStyle(
                      color: _textSub,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 5),
                  SizedBox(
                    width: 64,
                    height: 28,
                    child: TextFormField(
                      key: ValueKey(
                          'score-${q.id}-${q.meta['score_point'] ?? ''}'),
                      initialValue: scoreDraft,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                      ],
                      onChanged: (value) {
                        setState(() {
                          _scoreDrafts[q.id] = value;
                          _dirtyQuestionIds.add(q.id);
                        });
                      },
                      textAlign: TextAlign.end,
                      style: const TextStyle(color: _text, fontSize: 12.4),
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 6),
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
                        hintStyle:
                            const TextStyle(color: _textSub, fontSize: 11),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Text(
                    '점',
                    style: TextStyle(color: _textSub, fontSize: 11.5),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 5),
          const Text(
            '문제 미리보기',
            style: TextStyle(color: _textSub, fontSize: 11),
          ),
          const SizedBox(height: 3),
          InkWell(
            onTap: () {
              final status =
                  (_questionPreviewStatus[q.id.trim()] ?? '').trim().toLowerCase();
              if (status == 'failed' || status == 'cancelled') {
                _retryQuestionPreview(q.id.trim());
                return;
              }
              unawaited(_openPreviewZoomDialog(q));
            },
            borderRadius: BorderRadius.circular(8),
            child: _buildPdfPreviewThumbnail(q, compact: true),
          ),
          const SizedBox(height: 5),
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
          const SizedBox(height: 2),
          _buildAnswerPreviewThumbnail(q),
          if (q.figureRefs.isNotEmpty) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                const Text(
                  'AI 그림',
                  style: TextStyle(color: _textSub, fontSize: 11),
                ),
                const SizedBox(width: 6),
                InkWell(
                  onTap: () => unawaited(_openFigureScaleDialog(q)),
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFF172028),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: const Color(0xFF374553)),
                    ),
                    child: Text(
                      figureScaleButtonLabel,
                      style: const TextStyle(
                        color: _textSub,
                        fontSize: 10.4,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
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
                  tooltip: 'AI 그림 비교/생성',
                  iconSize: 17,
                  visualDensity:
                      const VisualDensity(horizontal: -4, vertical: -4),
                  onPressed: figureGenerating
                      ? null
                      : () => unawaited(_openFigureCompareDialog(q)),
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
          const SizedBox(height: 4),
          SizedBox(
            width: double.infinity,
            child: Text(
              metaFooter,
              textAlign: TextAlign.right,
              style: const TextStyle(color: _textSub, fontSize: 10.8),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              IconButton(
                tooltip: '이 문항 재추출',
                iconSize: 18,
                onPressed: canReextractThisQuestion
                    ? () => unawaited(_reextractQuestion(q))
                    : null,
                icon: isReextractingThisQuestion
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.8,
                          color: _textSub,
                        ),
                      )
                    : const Icon(
                        Icons.refresh,
                        color: _textSub,
                      ),
              ),
              const Spacer(),
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

  /// GridView는 자식에게 세로 tight 제약을 주어 카드 하단에 빈 칸이 생긴다.
  /// `maxCrossAxisExtent: 420`과 유사한 열 수로 [Wrap]에 맡겨 높이는 내용만큼만 쓴다.
  Widget _buildQuestionGridWrap() {
    const maxCard = 420.0;
    const gap = 10.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        if (!w.isFinite || w <= 0) {
          return const SizedBox.shrink();
        }
        var cols = 1;
        while (cols < 50) {
          final cw = (w - gap * (cols - 1)) / cols;
          if (cw <= maxCard + 1e-9) break;
          cols++;
        }
        final cardW = (w - gap * (cols - 1)) / cols;
        return SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final q in _visibleQuestions)
                  SizedBox(
                    width: cardW,
                    child: _buildQuestionGridCard(q),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildQuestionTable() {
    final unsavedCount =
        _dirtyQuestionIds.length + (_dirtyDocumentMeta ? 1 : 0);
    final objectiveCount =
        _questions.where((q) => q.questionType.contains('객관식')).length;
    final subjectiveCount =
        _questions.where((q) => q.questionType.contains('주관식')).length;
    final essayCount =
        _questions.where((q) => q.questionType.contains('서술')).length;
    final totalScore = _questions.fold<double>(0, (sum, q) {
      final parsed = _parseScoreDraft(_scoreDraftFor(q));
      return sum + (parsed ?? 0);
    });
    final roundedTotal = totalScore.roundToDouble();
    final totalScoreLabel = roundedTotal == totalScore
        ? '${roundedTotal.toInt()}점'
        : '${totalScore.toStringAsFixed(1)}점';
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
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text(
                '추출 현황',
                style: TextStyle(
                    color: _textSub, fontSize: 12, fontWeight: FontWeight.w700),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _field,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _border),
                ),
                child: Text('객관식 $objectiveCount개',
                    style: const TextStyle(color: _textSub, fontSize: 11)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _field,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _border),
                ),
                child: Text('주관식 $subjectiveCount개',
                    style: const TextStyle(color: _textSub, fontSize: 11)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _field,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _border),
                ),
                child: Text('서술형 $essayCount개',
                    style: const TextStyle(color: _textSub, fontSize: 11)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _field,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _border),
                ),
                child: Text('총점 $totalScoreLabel',
                    style: const TextStyle(color: _textSub, fontSize: 11)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                '총 ${_questions.length}문항 · 선택 $_checkedCount문항 · 저신뢰 $_lowConfidenceCount문항'
                '${unsavedCount > 0 ? ' · 저장대기 $unsavedCount건' : ''}',
                style: const TextStyle(
                  color: _textSub,
                  fontSize: 12,
                ),
              ),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: _activeDocument == null ||
                        (_dirtyQuestionIds.isEmpty &&
                            !_dirtyDocumentMeta &&
                            !_needsPublish) ||
                        _isSavingQuestionChanges ||
                        _isDeletingCurrentQuestions
                    ? null
                    : () => unawaited(_saveQuestionsToServer()),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _accent,
                  side: const BorderSide(color: _accent),
                ),
                icon: _isSavingQuestionChanges
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.8,
                          color: _accent,
                        ),
                      )
                    : const Icon(Icons.cloud_upload_outlined, size: 16),
                label: const Text('업로드'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _activeDocument == null ||
                        _checkedCount == 0 ||
                        _isSavingQuestionChanges ||
                        _isDeletingCurrentQuestions ||
                        _isUploading ||
                        _isExtracting
                    ? null
                    : () => unawaited(_reextractCheckedQuestions()),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF5EAFE8),
                  side: const BorderSide(color: Color(0xFF5EAFE8)),
                ),
                icon: (_isExtracting && _reextractingQuestionIds.isNotEmpty)
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.8,
                          color: Color(0xFF5EAFE8),
                        ),
                      )
                    : const Icon(Icons.refresh, size: 16),
                label: const Text('체크 재추출'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _questions.isEmpty ||
                        _isSavingQuestionChanges ||
                        _isDeletingCurrentQuestions
                    ? null
                    : () => unawaited(_deleteCurrentDocumentQuestions()),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFDE6A73),
                  side: const BorderSide(color: Color(0xFFDE6A73)),
                ),
                icon: _isDeletingCurrentQuestions
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.8,
                          color: Color(0xFFDE6A73),
                        ),
                      )
                    : const Icon(Icons.delete_outline, size: 16),
                label: const Text('이번 문항 삭제'),
              ),
              const SizedBox(width: 8),
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
                : _buildQuestionGridWrap(),
          ),
        ],
      ),
    );
  }

  Future<void> _runClassificationSearch() async {
    final academyId = _academyId;
    if (academyId == null || academyId.isEmpty) return;
    if (!mounted) return;
    setState(() {
      _isSearchingClassification = true;
    });
    try {
      final docs = await _service.searchDocuments(
        academyId: academyId,
        curriculumCode: _classificationCurriculumFilter.trim().isEmpty
            ? null
            : _classificationCurriculumFilter,
        sourceTypeCode: _classificationSourceTypeFilter.trim().isEmpty
            ? null
            : _classificationSourceTypeFilter,
        gradeLabel: _classificationGradeFilterCtrl.text.trim(),
        examYear: int.tryParse(_classificationYearFilterCtrl.text.trim()),
        schoolName: _classificationSchoolFilterCtrl.text.trim(),
        limit: 300,
      );
      final countByDocumentId = <String, int>{};
      var filteredDocs = docs;
      if (_classificationQuestionTypeFilter.trim().isNotEmpty) {
        final matchedQuestions = await _service.searchQuestions(
          academyId: academyId,
          curriculumCode: _classificationCurriculumFilter.trim().isEmpty
              ? null
              : _classificationCurriculumFilter,
          sourceTypeCode: _classificationSourceTypeFilter.trim().isEmpty
              ? null
              : _classificationSourceTypeFilter,
          gradeLabel: _classificationGradeFilterCtrl.text.trim(),
          examYear: int.tryParse(_classificationYearFilterCtrl.text.trim()),
          schoolName: _classificationSchoolFilterCtrl.text.trim(),
          questionType: _classificationQuestionTypeFilter,
          limit: 400,
        );
        for (final q in matchedQuestions) {
          countByDocumentId[q.documentId] =
              (countByDocumentId[q.documentId] ?? 0) + 1;
        }
        final docIds = countByDocumentId.keys.toSet();
        filteredDocs =
            docs.where((d) => docIds.contains(d.id)).toList(growable: false);
        if (filteredDocs.isEmpty && docIds.isNotEmpty) {
          final recentDocs = await _service.listRecentDocuments(
            academyId: academyId,
            limit: 300,
          );
          filteredDocs = recentDocs
              .where((d) => docIds.contains(d.id))
              .toList(growable: false);
        }
      }
      final results = filteredDocs
          .map(
            (doc) => _ClassificationDocumentResult(
              document: doc,
              matchedQuestionCount: countByDocumentId[doc.id] ?? -1,
            ),
          )
          .toList(growable: false);
      if (!mounted) return;
      setState(() {
        _classificationResults = results;
      });
    } catch (e) {
      _showSnack('분류 검색 실패: $e', error: true);
    } finally {
      if (mounted) {
        setState(() {
          _isSearchingClassification = false;
        });
      }
    }
  }

  void _resetClassificationFilters() {
    if (!mounted) return;
    setState(() {
      _classificationCurriculumFilter = '';
      _classificationSourceTypeFilter = '';
      _classificationQuestionTypeFilter = '';
      _classificationYearFilterCtrl.clear();
      _classificationGradeFilterCtrl.clear();
      _classificationSchoolFilterCtrl.clear();
      _classificationResults = <_ClassificationDocumentResult>[];
    });
    unawaited(_runClassificationSearch());
  }

  Future<void> _openDocumentFromClassification(ProblemBankDocument doc) async {
    if (!mounted) return;
    setState(() {
      _activeDocument = doc;
      _questions = <ProblemBankQuestion>[];
      _dirtyQuestionIds.clear();
      _questionPreviewUrls.clear();
      _needsPublish = false;
      _applySourceMetaFromDocument(doc);
      _scoreDrafts.clear();
      _hasExtracted = false;
    });
    await _loadDocumentContext(doc.id);
  }

  Future<void> _openSyncedListDialog() async {
    final academyId = _academyId;
    if (academyId == null || academyId.trim().isEmpty) {
      _showSnack('아카데미 정보를 불러오지 못했습니다.', error: true);
      return;
    }
    if (!mounted) return;
    final selectedId = await showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (_) => ProblemBankSyncedListDialog(
        academyId: academyId,
        service: _service,
        curriculumLabels: _curriculumLabels,
        sourceTypeLabels: _sourceTypeLabels,
        initialCurriculumCode: _selectedCurriculumCode,
        initialSchoolLevel: _syncedListSchoolLevel,
        initialDetailedCourse: _syncedListDetailedCourse,
        initialSourceTypeCode: _selectedSourceTypeCode,
        initialSearchText: '',
        initialSelectedDocumentId: _activeDocument?.id,
        onDeleteDocument: _hardDeleteSyncedDocument,
      ),
    );
    if (!mounted) return;
    if (selectedId == null || selectedId.trim().isEmpty) return;
    await _loadDocumentContext(selectedId);
  }

  Future<bool> _hardDeleteSyncedDocument(ProblemBankDocument doc) async {
    final academyId = _academyId;
    if (academyId == null || academyId.trim().isEmpty) {
      _showSnack('아카데미 정보를 불러오지 못했습니다.', error: true);
      return false;
    }
    try {
      await _service.deleteDocument(academyId: academyId, document: doc);
      if (!mounted) return true;
      final wasActive = _activeDocument?.id == doc.id;
      setState(() {
        _documents = _documents
            .where((d) => d.id != doc.id)
            .toList(growable: false);
        if (wasActive) {
          _activeDocument = null;
          _questions = <ProblemBankQuestion>[];
          _dirtyQuestionIds.clear();
          _questionPreviewUrls.clear();
          _scoreDrafts.clear();
          _hasExtracted = false;
          _needsPublish = false;
        }
      });
      unawaited(_refreshDocuments());
      unawaited(_runClassificationSearch());
      _showSnack('"${doc.sourceFilename}" 문서를 삭제했습니다.');
      return true;
    } catch (e) {
      _showSnack('문서 삭제 실패: $e', error: true);
      return false;
    }
  }

  Future<void> _deleteActiveDocumentInClassification() async {
    if (_isDeletingClassificationDocument) return;
    final academyId = _academyId;
    final doc = _activeDocument;
    if (academyId == null || academyId.isEmpty || doc == null) {
      _showSnack('삭제할 문서를 먼저 선택해주세요.', error: true);
      return;
    }
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: _panel,
            title: const Text('문서 삭제', style: TextStyle(color: _text)),
            content: Text(
              '${doc.sourceFilename}\n문서와 관련 추출 문항을 삭제합니다.',
              style: const TextStyle(color: _textSub, fontSize: 13),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('취소'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFDE6A73),
                ),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('삭제'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    if (!mounted) return;
    setState(() {
      _isDeletingClassificationDocument = true;
    });
    try {
      await _service.deleteDocument(academyId: academyId, document: doc);
      if (!mounted) return;
      setState(() {
        _questions = <ProblemBankQuestion>[];
        _activeDocument = null;
        _dirtyQuestionIds.clear();
        _questionPreviewUrls.clear();
        _scoreDrafts.clear();
        _hasExtracted = false;
        _needsPublish = false;
      });
      await _refreshDocuments();
      await _runClassificationSearch();
      _showSnack('문서를 삭제했습니다.');
    } catch (e) {
      _showSnack('문서 삭제 실패: $e', error: true);
    } finally {
      if (mounted) {
        setState(() {
          _isDeletingClassificationDocument = false;
        });
      }
    }
  }

  Widget _buildClassificationResultsPanel() {
    return Expanded(
      child: Container(
        decoration: BoxDecoration(
          color: _panel,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _border),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '검색 결과 ${_classificationResults.length}건 · 작업본/확정본 포함',
                  style: const TextStyle(
                    color: _textSub,
                    fontSize: 12.6,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: _activeDocument == null ||
                          _isDeletingClassificationDocument
                      ? null
                      : () =>
                          unawaited(_deleteActiveDocumentInClassification()),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFDE6A73),
                    side: const BorderSide(color: Color(0xFFDE6A73)),
                    visualDensity:
                        const VisualDensity(horizontal: -2, vertical: -2),
                  ),
                  icon: _isDeletingClassificationDocument
                      ? const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.6,
                            color: Color(0xFFDE6A73),
                          ),
                        )
                      : const Icon(Icons.delete_outline, size: 14),
                  label: const Text('선택 문서 삭제'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _classificationResults.isEmpty
                  ? const Center(
                      child: Text(
                        '분류 검색 결과가 없습니다.',
                        style: TextStyle(color: _textSub, fontSize: 12),
                      ),
                    )
                  : ListView.separated(
                      itemCount: _classificationResults.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 6),
                      itemBuilder: (context, index) {
                        final item = _classificationResults[index];
                        final doc = item.document;
                        final isActive = _activeDocument?.id == doc.id;
                        final statusLabel = _labelOfDocumentStatus(doc.status);
                        final isDraftStatus =
                            _isDraftDocumentStatus(doc.status);
                        final scoreText = item.matchedQuestionCount >= 0
                            ? '매칭 ${item.matchedQuestionCount}문항'
                            : '문서 기준';
                        final yearText =
                            doc.examYear == null ? '' : '${doc.examYear}';
                        final subParts = <String>[
                          if (yearText.isNotEmpty) yearText,
                          if (doc.schoolName.trim().isNotEmpty)
                            doc.schoolName.trim(),
                          if (doc.gradeLabel.trim().isNotEmpty)
                            '${doc.gradeLabel.trim()}학년',
                        ];
                        return InkWell(
                          onTap: () =>
                              unawaited(_openDocumentFromClassification(doc)),
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: isActive
                                  ? _accent.withValues(alpha: 0.15)
                                  : _field,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isActive ? _accent : _border,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        doc.sourceFilename,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: _text,
                                          fontSize: 12.4,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isDraftStatus
                                            ? const Color(0xFF7A5B2E)
                                            : const Color(0xFF2C8C66),
                                        borderRadius:
                                            BorderRadius.circular(999),
                                      ),
                                      child: Text(
                                        statusLabel,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 10.2,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${_labelOfCurriculumCode(doc.curriculumCode)} · ${_labelOfSourceTypeCode(doc.sourceTypeCode)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: _textSub,
                                    fontSize: 11.2,
                                  ),
                                ),
                                if (subParts.isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    subParts.join(' · '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: _textSub,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 4),
                                Text(
                                  scoreText,
                                  style: const TextStyle(
                                    color: _textSub,
                                    fontSize: 10.8,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUploadTabBody() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 380,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildUploadPanel(),
                const SizedBox(height: 12),
                _buildDocumentClassificationPanel(),
              ],
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildQuestionTable(),
        ),
      ],
    );
  }

  Widget _buildClassificationTabBody() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 380,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ProblemBankClassificationFilterPanel(
                  panelColor: _panel,
                  fieldColor: _field,
                  borderColor: _border,
                  textColor: _text,
                  textSubColor: _textSub,
                  accentColor: _accent,
                  curriculumLabels: <String, String>{
                    '': '전체',
                    ..._curriculumLabels,
                  },
                  sourceTypeLabels: <String, String>{
                    '': '전체',
                    ..._sourceTypeLabels,
                  },
                  questionTypeLabels: _questionTypeFilterLabels,
                  selectedCurriculumCode: _classificationCurriculumFilter,
                  selectedSourceTypeCode: _classificationSourceTypeFilter,
                  selectedQuestionType: _classificationQuestionTypeFilter,
                  yearController: _classificationYearFilterCtrl,
                  gradeController: _classificationGradeFilterCtrl,
                  schoolController: _classificationSchoolFilterCtrl,
                  isSearching: _isSearchingClassification,
                  onCurriculumChanged: (v) {
                    setState(() {
                      _classificationCurriculumFilter = v;
                    });
                  },
                  onSourceTypeChanged: (v) {
                    setState(() {
                      _classificationSourceTypeFilter = v;
                    });
                  },
                  onQuestionTypeChanged: (v) {
                    setState(() {
                      _classificationQuestionTypeFilter = v;
                    });
                  },
                  onSearch: () => unawaited(_runClassificationSearch()),
                  onReset: _resetClassificationFilters,
                ),
                const SizedBox(height: 12),
                _buildClassificationResultsPanel(),
                const SizedBox(height: 12),
                _buildDocumentClassificationPanel(),
              ],
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildQuestionTable(),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final canUpload = !_bootstrapLoading &&
        !_schemaMissing &&
        !_academyMissing &&
        _academyId != null &&
        _academyId!.isNotEmpty;
    final canReset =
        canUpload && !_isResetting && !_isUploading && !_isExtracting;

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
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Text(
                      '문제은행',
                      style: TextStyle(
                        color: _text,
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(width: 14),
                    ProblemBankModeTabBar(
                      controller: _topTabController,
                      panelColor: _panel,
                      borderColor: _border,
                      textColor: _text,
                      textSubColor: _textSub,
                      accentColor: _accent,
                    ),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: (_isResetting || _academyId == null)
                          ? null
                          : () => unawaited(_openSyncedListDialog()),
                      style: FilledButton.styleFrom(
                        backgroundColor: _accent,
                        foregroundColor: Colors.white,
                      ),
                      icon: const Icon(Icons.list_alt_outlined, size: 18),
                      label: const Text('목록'),
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
                const SizedBox(height: 6),
                const Text(
                  'HWPX(한글+수식) 추출, 검수, DB화까지 한 흐름으로 관리합니다.',
                  style: TextStyle(color: _textSub, fontSize: 14),
                ),
                const SizedBox(height: 12),
                _buildPipelineMarquee(),
                const SizedBox(height: 12),
                Expanded(
                  child: TabBarView(
                    controller: _topTabController,
                    children: [
                      _buildUploadTabBody(),
                      _buildClassificationTabBody(),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class _ClassificationDocumentResult {
  const _ClassificationDocumentResult({
    required this.document,
    required this.matchedQuestionCount,
  });

  final ProblemBankDocument document;
  final int matchedQuestionCount;
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
