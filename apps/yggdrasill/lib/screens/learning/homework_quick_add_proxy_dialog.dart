import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/ai_summary.dart';
import '../../services/data_manager.dart';
import '../../services/homework_store.dart';
import '../../services/homework_test_grading_result_service.dart';
import '../../services/homework_time_defaults_service.dart';
import '../../services/learning_problem_bank_service.dart';
import '../../services/student_textbook_active_store.dart';
import '../../services/tenant_service.dart';
import '../../services/textbook_concept_units.dart';
import '../../services/textbook_explorer_service.dart';
import '../../widgets/app_snackbar.dart';
import '../../widgets/dialog_tokens.dart';
import '../../widgets/latex_text_renderer.dart';
import '../../widgets/utility_glass_dialog_shell.dart';
import '../../models/education_level.dart';
import '../../models/student.dart';
import '../../models/student_flow.dart';
import '../../utils/naesin_exam_context.dart';
import '../../utils/textbook_problem_source_order.dart';
import '../../utils/wonri_timed_test_v0.dart';
import '../design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';
import '../resources/textbook_explorer_view.dart';

typedef _SelectedMigratedConceptPage = ({
  int bigOrder,
  String bigName,
  int midOrder,
  String midName,
  int smallOrder,
  String smallKey,
  String smallName,
  int rawPage,
  int displayPage,
});

class HomeworkQuickAddProxyDialog extends StatefulWidget {
  final String studentId;
  final String? initialTitle;
  final Color? initialColor;
  final List<StudentFlow> flows;
  final String? initialFlowId;
  final bool childAddMode;
  final bool requirePlanDestination;
  final String? lockedGroupTitle;
  final String? lockedBookId;
  final String? lockedGradeLabel;
  const HomeworkQuickAddProxyDialog({
    required this.studentId,
    required this.flows,
    this.initialTitle,
    this.initialColor,
    this.initialFlowId,
    this.childAddMode = false,
    this.requirePlanDestination = false,
    this.lockedGroupTitle,
    this.lockedBookId,
    this.lockedGradeLabel,
  });
  @override
  State<HomeworkQuickAddProxyDialog> createState() =>
      HomeworkQuickAddProxyDialogState();
}

class HomeworkQuickAddProxyDialogState
    extends State<HomeworkQuickAddProxyDialog> {
  static const AnimationStyle _fastTreeExpansionStyle = AnimationStyle(
    duration: Duration(milliseconds: 120),
    reverseDuration: Duration(milliseconds: 90),
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  late final TextEditingController _title;
  late final TextEditingController _content;
  late final TextEditingController _rangeTitle;
  late final TextEditingController _rangeContent;
  late final TextEditingController _page;
  late final TextEditingController _count;
  late final TextEditingController _timeLimitMinutes;
  late final TextEditingController _memo;
  late final TextEditingController _groupTitle;
  String _type = '프린트';

  /// 연결 교재로 과제를 만들 때 사용하는 유형 (기본 교재).
  String _linkedHomeworkType = '교재';

  /// 마이그레이션 교재 과제용 단계 선택. UI만 유지 (동작 미연결).
  String _migratedProblemStage = '원본';
  late String _flowId;
  bool _loadingFlowTextbooks = false;
  bool _loadingAllFlowTextbooks = false;
  bool _loadingMetadata = false;
  bool _manualPageMode = false;
  String _rangePickerMode = 'page';
  List<_LinkedTextbook> _linkedTextbooks = const <_LinkedTextbook>[];
  List<_LinkedTextbook> _allLinkedTextbooks = const <_LinkedTextbook>[];
  Map<String, bool> _textbookActiveOverrides = const <String, bool>{};
  String? _selectedLinkedBookKey;

  /// 선택 교재 payload `series` (`ssen` / `rpm` / `wonri` …).
  String? _linkedBookSeriesKey;
  List<_BigUnitSelectionNode> _units = const <_BigUnitSelectionNode>[];
  List<_TextbookProblemRegion> _problemRegions =
      const <_TextbookProblemRegion>[];
  final Set<String> _selectedProblemRegionIds = <String>{};
  TextbookExplorerController? _migratedExplorer;
  String? _migratedExplorerBookKey;
  String _migratedConceptPageSelectionFingerprint = '';
  String _rangeAutoPage = '';
  String _rangeAutoCount = '';
  String _rangeAutoScope = '-';
  List<Map<String, dynamic>> _rangeAutoUnitMappings =
      const <Map<String, dynamic>>[];
  bool _rangeAiLoading = false;
  int _rangeAiRequestId = 0;

  /// 출제 옵션(시간 분할) UI 제거 후 고정값. API 호환을 위해 전송 필드만 유지.
  static const int _defaultSplitParts = 1;
  bool _detailsPanelExpanded = false;
  String? _selectedPlanDestination;
  final List<_DraftGroupItem> _draftGroupItems = <_DraftGroupItem>[];
  int _draftGroupItemSeq = 0;

  /// 사용자가 그룹 제목을 직접 수정하면 true. 이후 자동 갱신이 덮어쓰지 않는다.
  bool _groupTitleManuallyEdited = false;
  bool _suppressGroupTitleListener = false;

  /// 오른쪽 페이지 패널에 표시할 중단원 (`big:i|mid:j`).
  String? _activeMidKey;
  String? _activeTypeSmallKey;

  /// 왼쪽 소단원 탭 후 오른쪽에서 해당 소단원 헤더로 스크롤.
  String? _pendingScrollSmallExpandKey;

  /// 펼쳐진 소단원 목록이 속한 중단원(`_midExpandKey`). 한 번에 하나만 펼침.
  String? _expandedLeftMidSmallsKey;

  static const Duration _kTreeSmallsExpandDuration =
      Duration(milliseconds: 240);
  static const Curve _kTreeSmallsExpandCurve = Curves.easeInOutCubic;

  /// 페이지 리스트 한 줄 높이(디바이더 포함 영역과 동일).
  static const double _kSmallPageListRowStride = 54;

  /// 오른쪽 패널 소단원 구간 헤더 높이.
  static const double _kMidRightSmallHeaderHeight = 49;

  /// 트리 체크박스 열과 제목 열 사이 (기준 6의 1.5배).
  static const double _kLeftSmallCheckboxToTitleGap = 9;

  /// 대단원 하위 중단원 열의 왼쪽 들여쓰기; 소단원 목록에 한 단계 더 동일 적용.
  static const double _kTreeMidIndentFromBig = 22;

  final ScrollController _rangeRightScrollController = ScrollController();
  final ScrollController _leftTreeScrollController = ScrollController();
  final ScrollController _rangeFallbackScrollController = ScrollController();
  final ScrollController _inputPanelScrollController = ScrollController();
  final ScrollController _rangeContentScrollController = ScrollController();
  final Map<String, GlobalKey> _smallHeaderKeys = <String, GlobalKey>{};
  final Map<String, GlobalKey> _leftSmallRowKeys = <String, GlobalKey>{};

  static const double _kLeftSmallDragSlopPx = 6;
  static const double _kLeftSmallCheckboxHitWidth = 44;

  bool _leftSmallDragPointerDown = false;
  bool _leftSmallDragMovedPastSlop = false;
  Offset? _leftSmallDragDownGlobal;
  String? _leftSmallDragAnchorExpandKey;
  bool? _leftSmallDragSelectMode;
  Map<String, _SmallDragSnap>? _leftSmallDragBaseline;

  int? _pageListDragAnchorIndex;
  bool? _pageListDragSelectMode;

  /// 페이지 드래그 시작 시점의 소단원별 `selectedPages` (드래그 중 구간은 이 기준에 ∪ / −).
  List<Set<int>>? _pageListDragBaselineBySmallIndex;

  bool _rightPagePointerDown = false;
  Offset? _rightPagePointerDownLocal;
  bool _rightPageDragMoved = false;

  /// `whole` = 소단원 헤더 줄 드래그, `page` = 페이지 줄 드래그.
  String _rightPageSessionKind = '';
  int? _rightPageWholeAnchorSmallIdx;
  bool? _rightPageWholeSelectMode;
  int? _rightPagePageSmallIdx;
  bool _rightProblemPointerDown = false;
  Offset? _rightProblemPointerDownLocal;
  bool _rightProblemDragMoved = false;
  int? _problemListDragAnchorIndex;
  bool? _problemListDragSelectMode;
  Set<String>? _problemListDragBaseline;

  static const String _kTestSourceNaesin = 'naesin';
  static const String _kNaesinDraftLinkPrefix = '__naesin__';
  static const String _kNaesinLinkConfigKey = 'naesinLinkKey';
  static const List<String> _kNaesinExamTerms = <String>['중간고사', '기말고사'];
  static const List<int> _kNaesinYears = <int>[2021, 2022, 2023, 2024, 2025];
  static const double _kNaesinGridYearLabelWidth = 50;
  static const double _kNaesinGridCellSize = 58;
  static const double _kNaesinGridMinCellSize = 36;
  static const double _kNaesinGridCellGap = 12;
  static const double _kNaesinGridMinCellGap = 10;
  static const double _kNaesinGridMinRowGap = 10;

  /// 라벨 열(년도)과 첫 학교 셀 열 사이.
  static const double _kNaesinGridLabelToCellsGap = 8;
  static const Color _kNaesinLinkedActiveCellColor = Color(0xFF282828);
  static const String _kTestFlowName = '테스트';

  String _testSource = _kTestSourceNaesin;
  bool _useNaesinSource = false;
  bool _useCustomSource = false;
  bool _showGroupPanel = false;

  /// 범위 선택 시 소단원 단위로 자동 분해해 제출. 해제 시 수동 하위 과제 추가.
  bool _autoSubtaskMode = true;

  /// 자동 모드 리스트와 현재 선택 범위의 동기화 지문.
  String? _autoDraftFingerprint;
  String? _testOriginFlowId;
  bool _testTimeLimitEnabled = true;
  bool _timedTestEligibilityLoading = false;
  int _timedTestEligibleCount = 0;
  int _timedTestExcludedCount = 0;
  String _timedTestEligibilityFingerprint = '';
  bool _submitting = false;
  String _naesinGradeKey = '';
  String _naesinCourseKey = '';
  String _naesinExamTerm = '';
  String _naesinStudentSchool = '';
  bool _naesinStandaloneMode = false;
  final LearningProblemBankService _problemBankService =
      LearningProblemBankService();
  final HomeworkTestGradingResultService _gradingResultService =
      HomeworkTestGradingResultService.instance;
  final Set<String> _naesinLinkedCellKeys = <String>{};
  final Map<String, _NaesinPresetAutoValues> _naesinAutoValuesByCellKey =
      <String, _NaesinPresetAutoValues>{};
  final Map<String, _NaesinCellStatus> _naesinCellStatusByLinkKey =
      <String, _NaesinCellStatus>{};
  bool _loadingNaesinLinkedCellKeys = false;
  Future<void>? _naesinDataLoadFuture;

  bool get _isChildAddMode => widget.childAddMode;

  List<String> get _naesinSchools =>
      NaesinExamContext.schoolsForGradeKey(_naesinGradeKey);

  String? get _lockedBookIdentity {
    final bookId = (widget.lockedBookId ?? '').trim();
    final gradeLabel = (widget.lockedGradeLabel ?? '').trim();
    if (bookId.isEmpty || gradeLabel.isEmpty) return null;
    return '$bookId|$gradeLabel';
  }

  String? _lockedLinkedBookKeyForFlow(String flowId) {
    final identity = _lockedBookIdentity;
    if (identity == null) return null;
    final cleanedFlowId = flowId.trim();
    if (cleanedFlowId.isEmpty) return null;
    return '$cleanedFlowId|$identity';
  }

  _LinkedTextbook? get _selectedLinkedBook {
    final key = _selectedLinkedBookKey;
    if (key == null) return null;
    for (final item in _linkedTextbooks) {
      if (item.key == key) return item;
    }
    return null;
  }

  StudentFlow? get _testFlow {
    for (final flow in widget.flows) {
      if (flow.name.trim() == _kTestFlowName) return flow;
    }
    return null;
  }

  bool _isTestFlowId(String flowId) {
    final cleaned = flowId.trim();
    if (cleaned.isEmpty) return false;
    for (final flow in widget.flows) {
      if (flow.id == cleaned && flow.name.trim() == _kTestFlowName) {
        return true;
      }
    }
    return false;
  }

  String? _currentTestOriginFlowId() {
    final explicit = (_testOriginFlowId ?? '').trim();
    if (explicit.isNotEmpty) return explicit;
    final currentFlowId = _flowId.trim();
    return _isTestFlowId(currentFlowId) ? currentFlowId : null;
  }

  @override
  void initState() {
    super.initState();
    _title = ImeAwareTextEditingController(text: widget.initialTitle ?? '');
    _content = ImeAwareTextEditingController(text: '');
    _rangeTitle = ImeAwareTextEditingController(text: '');
    _rangeContent = ImeAwareTextEditingController(text: '');
    _page = ImeAwareTextEditingController(text: '');
    _count = ImeAwareTextEditingController(text: '');
    _timeLimitMinutes = ImeAwareTextEditingController(text: '');
    _memo = ImeAwareTextEditingController(text: '');
    final initialGroupTitle = _isChildAddMode
        ? (widget.lockedGroupTitle ?? widget.initialTitle ?? '').trim()
        : (widget.initialTitle ?? '').trim();
    _groupTitle = ImeAwareTextEditingController(
      text: initialGroupTitle.isEmpty ? '그룹 과제' : initialGroupTitle,
    );
    if (initialGroupTitle.isNotEmpty && !_isChildAddMode) {
      _groupTitleManuallyEdited = true;
    }
    _groupTitle.addListener(_onGroupTitleEdited);
    final initial = widget.initialFlowId;
    if (initial != null && widget.flows.any((f) => f.id == initial)) {
      _flowId = initial;
    } else {
      _flowId = widget.flows.isNotEmpty ? widget.flows.first.id : '';
    }
    _initNaesinFilterDefaults();
    unawaited(_loadAllFlowLinkedBooks());
    // 권장시간 단가 미리 로드 (없으면 권장시간 표시가 조용히 꺼진다).
    unawaited(
      HomeworkTimeDefaultsService.instance.ensureLoaded().then((_) {
        if (mounted) setState(() {});
      }),
    );
  }

  @override
  void didUpdateWidget(covariant HomeworkQuickAddProxyDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.flows != widget.flows) {
      unawaited(_loadAllFlowLinkedBooks());
    }
  }

  @override
  void dispose() {
    _disposeMigratedExplorer();
    _title.dispose();
    _content.dispose();
    _rangeTitle.dispose();
    _rangeContent.dispose();
    _page.dispose();
    _count.dispose();
    _timeLimitMinutes.dispose();
    _memo.dispose();
    _groupTitle.removeListener(_onGroupTitleEdited);
    _groupTitle.dispose();
    _rangeRightScrollController.dispose();
    _leftTreeScrollController.dispose();
    _rangeFallbackScrollController.dispose();
    _inputPanelScrollController.dispose();
    _rangeContentScrollController.dispose();
    super.dispose();
  }

  void _disposeMigratedExplorer() {
    final controller = _migratedExplorer;
    if (controller == null) return;
    controller.removeListener(_syncMigratedExplorerSelection);
    controller.dispose();
    _migratedExplorer = null;
    _migratedExplorerBookKey = null;
    _migratedConceptPageSelectionFingerprint = '';
  }

  InputDecoration _inputDecoration(String label, {String? hint}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      labelStyle: const TextStyle(color: kDlgTextSub),
      hintStyle: const TextStyle(color: Color(0xFF6E7E7E)),
      filled: true,
      fillColor: kDlgFieldBg,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: kDlgBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: kDlgAccent, width: 1.4),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    );
  }

  static const List<String> _homeworkTypeValues = <String>[
    '프린트',
    '교재',
    '학습',
  ];

  static const List<String> _migratedProblemStageValues = <String>[
    '원본',
    '1단계',
    '2단계',
    '3단계',
  ];

  /// 라벨 → `homework_item_problems.source_stage` 코드.
  static const Map<String, String> _migratedProblemStageCodes =
      <String, String>{
    '원본': 'original',
    '1단계': 'variant1',
    '2단계': 'variant2',
    '3단계': 'variant3',
  };

  /// 변형 문항 파이프라인이 아직 없어 원본만 출제할 수 있다.
  static const Set<String> _migratedProblemStageEnabled = <String>{'원본'};

  String get _migratedProblemStageCode =>
      _migratedProblemStageCodes[_migratedProblemStage] ?? 'original';

  Color _colorForType(String type) {
    switch (type) {
      case '프린트':
        return Colors.blue;
      case '교재':
        return Colors.green;
      case '문제집':
        return Colors.green;
      case '학습':
        return Colors.purple;
      case '테스트':
        return Colors.red;
      default:
        return Colors.blue;
    }
  }

  String _composeBodyValues({
    required String page,
    required String count,
    required String content,
    int? timeLimitMinutes,
  }) {
    final parts = <String>[];
    if (page.isNotEmpty) parts.add('p.$page');
    if (count.isNotEmpty) parts.add('${count}문항');
    if (timeLimitMinutes != null && timeLimitMinutes > 0) {
      parts.add('제한시간 ${timeLimitMinutes}분');
    }
    if (parts.isEmpty) return content;
    if (content.isEmpty) return parts.join(' / ');
    return '${parts.join(' / ')}\n$content';
  }

  int? _parsePositiveIntText(String raw) {
    final normalized = raw.trim();
    if (normalized.isEmpty) return null;
    final parsed = int.tryParse(normalized);
    if (parsed == null || parsed <= 0) return null;
    return parsed;
  }

  String _formatPageRangeFromCount(int pageCount) {
    if (pageCount <= 0) return '';
    if (pageCount == 1) return '1';
    return '1-$pageCount';
  }

  bool _isTestTypeActive() {
    return _useNaesinSource || _isTestFlowId(_flowId);
  }

  bool _isCurrentHomeworkTypeTest() {
    return _isTestTypeActive();
  }

  bool _looksLikeWonriBook(_LinkedTextbook? book) {
    if (book == null) return false;
    final compact =
        book.bookName.trim().replaceAll(RegExp(r'\s+'), '').toLowerCase();
    return compact.contains('개념원리') || compact.contains('wonri');
  }

  bool _isWonriTimedTestV0Active() {
    return _isCurrentHomeworkTypeTest() &&
        !_useNaesinSource &&
        !_useCustomSource &&
        (_looksLikeWonriBook(_selectedLinkedBook) ||
            _isWonriLinkedBook(_selectedLinkedBook));
  }

  String _timedTestCategoryLabel(_TextbookProblemRegion region) {
    return <String>[
      region.wonriTypeName,
      region.typeGroupLabel,
      region.typeTitle,
      region.typeLabel,
      region.label,
      region.section,
    ].where((value) => value.trim().isNotEmpty).join(' ');
  }

  String _timedTestSelectionSeedMaterial(
    _LinkedTextbook book,
    Iterable<_TextbookProblemRegion> regions,
  ) {
    final ids = regions.map((region) => region.id.trim()).toList()..sort();
    return '${widget.studentId}|${book.bookId}|${book.gradeLabel}|${ids.join(',')}';
  }

  Future<
      ({
        List<_TextbookProblemRegion> eligible,
        int excluded,
        String seedMaterial,
      })> _loadWonriTimedTestEligibility(
    _LinkedTextbook book,
  ) async {
    final selected = _selectedProblemRegions();
    final seedMaterial = _timedTestSelectionSeedMaterial(book, selected);
    if (selected.isEmpty) {
      return (
        eligible: const <_TextbookProblemRegion>[],
        excluded: 0,
        seedMaterial: seedMaterial,
      );
    }
    final rows =
        await DataManager.instance.loadTextbookProblemRegionsForGrading(
      bookId: book.bookId,
      gradeLabel: book.gradeLabel,
      cropIds: selected.map((region) => region.id),
    );
    final rowsById = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      final id = '${row['id'] ?? row['crop_id'] ?? ''}'.trim();
      if (id.isNotEmpty) rowsById[id] = row;
    }
    final eligible = <_TextbookProblemRegion>[];
    for (final region in selected) {
      final row = rowsById[region.id];
      if (region.isSetHeader ||
          row == null ||
          !isWonriTimedTestAutoGradable(row)) {
        continue;
      }
      eligible.add(region);
    }
    final ordered = wonriTimedTestWeightedOrder<_TextbookProblemRegion>(
      candidates: eligible,
      categoryLabelOf: _timedTestCategoryLabel,
      stableIdOf: (region) => region.id,
      seedMaterial: seedMaterial,
    );
    return (
      eligible: ordered,
      excluded: selected.length - ordered.length,
      seedMaterial: seedMaterial,
    );
  }

  Future<void> _refreshWonriTimedTestEligibility() async {
    final book = _selectedLinkedBook;
    if (book == null || !_isWonriTimedTestV0Active()) {
      if (!mounted) return;
      if (_timedTestEligibilityFingerprint.isEmpty &&
          _timedTestEligibleCount == 0 &&
          _timedTestExcludedCount == 0 &&
          !_timedTestEligibilityLoading) {
        return;
      }
      setState(() {
        _timedTestEligibilityFingerprint = '';
        _timedTestEligibleCount = 0;
        _timedTestExcludedCount = 0;
        _timedTestEligibilityLoading = false;
      });
      return;
    }
    final selected = _selectedProblemRegions();
    final fingerprint = _timedTestSelectionSeedMaterial(book, selected);
    if (fingerprint == _timedTestEligibilityFingerprint) return;
    setState(() {
      _timedTestEligibilityFingerprint = fingerprint;
      _timedTestEligibilityLoading = true;
      _timedTestEligibleCount = 0;
      _timedTestExcludedCount = 0;
    });
    try {
      final result = await _loadWonriTimedTestEligibility(book);
      if (!mounted ||
          _selectedLinkedBook?.key != book.key ||
          _timedTestEligibilityFingerprint != fingerprint) {
        return;
      }
      setState(() {
        _timedTestEligibleCount = result.eligible.length;
        _timedTestExcludedCount = result.excluded;
        _timedTestEligibilityLoading = false;
      });
    } catch (_) {
      if (!mounted || _timedTestEligibilityFingerprint != fingerprint) return;
      setState(() {
        _timedTestEligibleCount = 0;
        _timedTestExcludedCount = selected.length;
        _timedTestEligibilityLoading = false;
      });
    }
  }

  int _semesterFromNaesinCourseKey(String courseKey) {
    final normalized = courseKey.trim().toLowerCase();
    if (normalized.endsWith('-2') || normalized.endsWith('c2')) {
      return 2;
    }
    return 1;
  }

  String _naesinExamTermShort(String examTerm) {
    final normalized = examTerm.trim();
    if (normalized.contains('기말')) return '기말';
    return '중간';
  }

  String _naesinGradeYearLabel(String gradeKey) {
    final matched = RegExp(r'(\d)').firstMatch(gradeKey.trim());
    final year = int.tryParse(matched?.group(1) ?? '');
    if (year == null || year <= 0) return '1학년';
    return '${year}학년';
  }

  String _naesinChildHomeworkTitle() {
    final semester = _semesterFromNaesinCourseKey(_naesinCourseKey);
    final term = _naesinExamTermShort(_naesinExamTerm);
    return '${semester}학기 $term';
  }

  String _naesinGroupTitleForCell({
    required String school,
    required int year,
  }) {
    final gradeLabel = _naesinGradeYearLabel(_naesinGradeKey);
    return '$year $school $gradeLabel 내신 기출';
  }

  String _naesinCourseLabel(String courseKey) {
    return NaesinExamContext.courseLabel(courseKey);
  }

  int _safeIntFromDynamic(dynamic raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse('$raw') ?? 0;
  }

  int? _parseTimeLimitMinutesFromPresetRenderConfig(
    Map<String, dynamic> renderConfig,
  ) {
    final raw = '${renderConfig['timeLimitText'] ?? ''}'.trim();
    if (raw.isEmpty) return null;
    final matched = RegExp(r'(\d{1,4})').firstMatch(raw);
    final parsed = int.tryParse(matched?.group(1) ?? '');
    if (parsed == null || parsed <= 0) return null;
    return parsed;
  }

  int? _estimateQuestionPageCountFromPreset({
    required Map<String, dynamic> renderConfig,
    required int questionCount,
  }) {
    final rawPageRows = renderConfig['pageColumnQuestionCounts'];
    if (rawPageRows is List) {
      var maxPageIndex = 0;
      for (final row in rawPageRows) {
        if (row is! Map) continue;
        final map = Map<String, dynamic>.from(row);
        final pageIndex = _safeIntFromDynamic(
          map['pageIndex'] ?? map['page'] ?? map['pageNo'],
        );
        final left = _safeIntFromDynamic(
          map['left'] ?? map['leftCount'] ?? map['col1'],
        );
        final right = _safeIntFromDynamic(
          map['right'] ?? map['rightCount'] ?? map['col2'],
        );
        if (pageIndex <= 0 || left + right <= 0) continue;
        if (pageIndex > maxPageIndex) {
          maxPageIndex = pageIndex;
        }
      }
      if (maxPageIndex > 0) return maxPageIndex;
    }
    if (questionCount <= 0) return null;
    final layoutColumns = _safeIntFromDynamic(renderConfig['layoutColumns']);
    final defaultPerPage = layoutColumns == 2 ? 8 : 4;
    final maxQuestionsPerPage = _safeIntFromDynamic(
      renderConfig['maxQuestionsPerPage'],
    );
    final perPage =
        maxQuestionsPerPage > 0 ? maxQuestionsPerPage : defaultPerPage;
    if (perPage <= 0) return null;
    return ((questionCount + perPage - 1) / perPage).floor();
  }

  bool _hasNaesinDraftItems() {
    for (final item in _draftGroupItems) {
      final key = (item.linkedBookKey ?? '').trim();
      if (key.startsWith(_kNaesinDraftLinkPrefix)) return true;
    }
    return false;
  }

  bool _shouldShowNaesinPanel() {
    return _useNaesinSource && _testSource == _kTestSourceNaesin;
  }

  Future<void> _enterNaesinStandaloneMode(String testFlowId) async {
    final previousFlowId = _isTestFlowId(_flowId) ? null : _flowId.trim();
    setState(() {
      _naesinStandaloneMode = true;
      _showGroupPanel = false;
      _useNaesinSource = true;
      _useCustomSource = false;
      _testSource = _kTestSourceNaesin;
      _testOriginFlowId = previousFlowId;
      _flowId = testFlowId;
      _selectedLinkedBookKey = null;
      _linkedHomeworkType = '프린트';
      _type = '프린트';
      _manualPageMode = false;
      _units = const <_BigUnitSelectionNode>[];
      _expandedLeftMidSmallsKey = null;
      _draftGroupItems.clear();
    });
    if (_naesinGradeKey.isEmpty ||
        _naesinCourseKey.isEmpty ||
        _naesinExamTerm.isEmpty) {
      _initNaesinFilterDefaults();
    }
    await Future.wait<void>([
      _ensureNaesinDataLoaded(),
      _handleFlowChanged(forceNoBookSelection: true),
    ]);
  }

  StudentWithInfo? _studentInfoForDialog() {
    for (final row in DataManager.instance.students) {
      if (row.student.id == widget.studentId) return row;
    }
    return null;
  }

  List<_NaesinGradeOption> get _naesinAllGradeOptions {
    return NaesinExamContext.allGradeOptions()
        .map(
          (e) => _NaesinGradeOption(
            key: e.key,
            label: e.label,
            level: e.level,
            grade: e.grade,
          ),
        )
        .toList();
  }

  List<_NaesinCourseOption> _naesinCourseOptionsForGrade(String gradeKey) {
    return NaesinExamContext.courseOptionsForGrade(gradeKey)
        .map((e) => _NaesinCourseOption(key: e.key, label: e.label))
        .toList();
  }

  void _initNaesinFilterDefaults() {
    final now = DateTime.now();
    final info = _studentInfoForDialog();
    final derived = NaesinExamContext.initialGradeCourseFromStudent(
      info?.student,
      now,
    );
    _naesinGradeKey = derived.gradeKey;
    _naesinCourseKey = derived.courseKey;
    _naesinExamTerm = NaesinExamContext.defaultNaesinExamTermByDate(now);
    _naesinStudentSchool = (info?.student.school ?? '').trim();
  }

  void _syncNaesinCourseWithGrade() {
    final courseOptions = _naesinCourseOptionsForGrade(_naesinGradeKey);
    if (courseOptions.any((e) => e.key == _naesinCourseKey)) return;
    _naesinCourseKey = courseOptions.first.key;
  }

  List<_NaesinLinkedCellOption> _naesinLinkedOptionsForSchoolYear({
    required String school,
    required int year,
  }) {
    final out = <_NaesinLinkedCellOption>[];
    for (final key in _naesinLinkedCellKeys) {
      final parsed = NaesinExamContext.parseNaesinLinkKey(key);
      if (parsed == null) continue;
      if (parsed.gradeKey != _naesinGradeKey ||
          !NaesinExamContext.courseKeysEquivalentForNaesin(
            parsed.courseKey,
            _naesinCourseKey,
          ) ||
          parsed.examTerm != _naesinExamTerm ||
          parsed.school != school ||
          parsed.year != year) {
        continue;
      }
      out.add(
        _NaesinLinkedCellOption(
          linkKey: key,
          cellLabel: parsed.cellLabel,
          status: _naesinCellStatusByLinkKey[key],
        ),
      );
    }
    out.sort((a, b) {
      if (a.cellLabel.isEmpty && b.cellLabel.isNotEmpty) return -1;
      if (a.cellLabel.isNotEmpty && b.cellLabel.isEmpty) return 1;
      return a.cellLabel.compareTo(b.cellLabel);
    });
    return out;
  }

  int _naesinGridSlotCountForYear(int year) {
    final schools = _naesinSchools;
    var maxCount = 1;
    for (final school in schools) {
      maxCount = math.max(
        maxCount,
        _naesinLinkedOptionsForSchoolYear(school: school, year: year).length,
      );
    }
    return maxCount;
  }

  int _naesinGridVisualRowCount() {
    var count = 0;
    for (final year in _kNaesinYears) {
      count += _naesinGridSlotCountForYear(year);
    }
    return math.max(1, count);
  }

  DateTime _naesinStatusTimestampOfHomework(HomeworkItem item) {
    return item.completedAt ??
        item.confirmedAt ??
        item.submittedAt ??
        item.waitingAt ??
        item.updatedAt ??
        item.createdAt ??
        DateTime.fromMillisecondsSinceEpoch(0);
  }

  bool _isNaesinEndedHomework(HomeworkItem item) {
    return item.phase >= 3 || item.confirmedAt != null;
  }

  int _naesinElapsedMsOfHomework(HomeworkItem item) {
    final runningMs = item.runStart == null
        ? 0
        : DateTime.now().difference(item.runStart!).inMilliseconds;
    return math.max(0, item.accumulatedMs + runningMs);
  }

  String _formatNaesinElapsedDuration(int elapsedMs) {
    final safeMs = math.max(0, elapsedMs);
    final totalMinutes = safeMs ~/ 60000;
    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;
    if (hours > 0) {
      return '$hours시간 ${minutes.toString().padLeft(2, '0')}분';
    }
    return '${totalMinutes}분';
  }

  String _formatNaesinCellScoreValue(double value) {
    final rounded = value.roundToDouble();
    if ((value - rounded).abs() < 0.0001) {
      return rounded.toStringAsFixed(0);
    }
    return value.toStringAsFixed(1);
  }

  String _formatNaesinIssuedDate(DateTime value) {
    final local = value.toLocal();
    final mm = local.month.toString().padLeft(2, '0');
    final dd = local.day.toString().padLeft(2, '0');
    return '$mm.$dd';
  }

  String _formatNaesinIssuedDateTime(DateTime value) {
    final local = value.toLocal();
    final yyyy = local.year.toString().padLeft(4, '0');
    final mm = local.month.toString().padLeft(2, '0');
    final dd = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final min = local.minute.toString().padLeft(2, '0');
    return '$yyyy.$mm.$dd $hh:$min';
  }

  Future<Map<String, _NaesinCellStatus>> _buildNaesinCellStatusMap({
    required Set<String> linkedKeys,
  }) async {
    final grouped = <String, List<HomeworkItem>>{};
    final itemIds = <String>{};
    final homeworkItems = HomeworkStore.instance.items(widget.studentId);
    for (final item in homeworkItems) {
      if ((item.sourceUnitLevel ?? '').trim().toLowerCase() != 'naesin') {
        continue;
      }
      final linkKey = (item.sourceUnitPath ?? '').trim();
      if (linkKey.isEmpty) continue;
      final matchedLinkKey = linkedKeys.isEmpty
          ? linkKey
          : linkedKeys.firstWhere(
              (key) => NaesinExamContext.linkKeysEquivalentForNaesin(
                key,
                linkKey,
              ),
              orElse: () => '',
            );
      if (matchedLinkKey.isEmpty) continue;
      grouped.putIfAbsent(matchedLinkKey, () => <HomeworkItem>[]).add(item);
      final itemId = item.id.trim();
      if (itemId.isNotEmpty) itemIds.add(itemId);
    }
    if (grouped.isEmpty) return const <String, _NaesinCellStatus>{};
    final latestScoreByItemId =
        await _gradingResultService.loadLatestScoreByHomeworkItemIds(itemIds);
    final out = <String, _NaesinCellStatus>{};
    grouped.forEach((linkKey, rows) {
      DateTime? firstIssuedAt;
      HomeworkItem? target;
      HomeworkTestLatestScore? latestScore;
      var targetPriority = -1;
      var targetAt = DateTime.fromMillisecondsSinceEpoch(0);
      for (final item in rows) {
        final issuedAt = item.createdAt ?? item.updatedAt;
        if (issuedAt != null &&
            (firstIssuedAt == null || issuedAt.isBefore(firstIssuedAt))) {
          firstIssuedAt = issuedAt;
        }
        final isCompleted = item.status == HomeworkStatus.completed;
        final isEnded = _isNaesinEndedHomework(item);
        final priority = isCompleted ? 3 : (isEnded ? 2 : 1);
        final at = _naesinStatusTimestampOfHomework(item);
        if (target == null ||
            priority > targetPriority ||
            (priority == targetPriority && at.isAfter(targetAt))) {
          target = item;
          targetPriority = priority;
          targetAt = at;
        }
        final score = latestScoreByItemId[item.id.trim()];
        if (score != null &&
            (latestScore == null ||
                score.gradedAt.isAfter(latestScore.gradedAt))) {
          latestScore = score;
        }
      }
      if (target == null) return;
      final isCompleted = target.status == HomeworkStatus.completed;
      final isEnded = !isCompleted && _isNaesinEndedHomework(target);
      final scoreLabel = latestScore == null
          ? ''
          : '${_formatNaesinCellScoreValue(latestScore.scoreCorrect)}/${_formatNaesinCellScoreValue(latestScore.scoreTotal)}';
      out[linkKey] = _NaesinCellStatus(
        issuedAt: target.createdAt ?? target.updatedAt,
        firstIssuedAt: firstIssuedAt,
        elapsedMs: _naesinElapsedMsOfHomework(target),
        isEnded: isEnded,
        isCompleted: isCompleted,
        scoreLabel: scoreLabel,
      );
    });
    return out;
  }

  Future<void> _loadNaesinLinkedCellKeys() async {
    if (!mounted) return;
    setState(() => _loadingNaesinLinkedCellKeys = true);
    try {
      var academyId =
          (await TenantService.instance.getActiveAcademyId() ?? '').trim();
      if (academyId.isEmpty) {
        academyId = (await TenantService.instance.ensureActiveAcademy()).trim();
      }
      if (academyId.isEmpty) {
        if (!mounted) return;
        setState(() {
          _naesinLinkedCellKeys.clear();
          _naesinAutoValuesByCellKey.clear();
          _naesinCellStatusByLinkKey.clear();
        });
        return;
      }
      final presets = await _problemBankService.listExportPresets(
        academyId: academyId,
        limit: 500,
      );
      final linkedKeys = <String>{};
      final autoValuesByKey = <String, _NaesinPresetAutoValues>{};
      for (final preset in presets) {
        final key =
            '${preset.renderConfig[_kNaesinLinkConfigKey] ?? preset.naesinLinkKey}'
                .trim();
        if (key.isNotEmpty) {
          linkedKeys.add(key);
          final presetId = preset.id.trim();
          final questionCount = preset.selectedQuestionCount > 0
              ? preset.selectedQuestionCount
              : preset.selectedQuestionUids.length;
          final questionPageCount = _estimateQuestionPageCountFromPreset(
            renderConfig: preset.renderConfig,
            questionCount: questionCount,
          );
          final timeLimitMinutes = _parseTimeLimitMinutesFromPresetRenderConfig(
            preset.renderConfig,
          );
          autoValuesByKey.putIfAbsent(
            key,
            () => _NaesinPresetAutoValues(
              presetId: presetId.isEmpty ? null : presetId,
              questionCount: questionCount,
              questionPageCount: questionPageCount,
              timeLimitMinutes: timeLimitMinutes,
            ),
          );
        }
      }
      final statusByLinkKey =
          await _buildNaesinCellStatusMap(linkedKeys: linkedKeys);
      if (!mounted) return;
      setState(() {
        _naesinLinkedCellKeys
          ..clear()
          ..addAll(linkedKeys);
        _naesinAutoValuesByCellKey
          ..clear()
          ..addAll(autoValuesByKey);
        _naesinCellStatusByLinkKey
          ..clear()
          ..addAll(statusByLinkKey);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _naesinLinkedCellKeys.clear();
        _naesinAutoValuesByCellKey.clear();
        _naesinCellStatusByLinkKey.clear();
      });
    } finally {
      if (mounted) {
        setState(() => _loadingNaesinLinkedCellKeys = false);
      }
    }
  }

  Future<void> _ensureNaesinDataLoaded() {
    return _naesinDataLoadFuture ??= _loadNaesinLinkedCellKeys();
  }

  Future<void> _onNaesinStatusCellTapped({
    required String school,
    required int year,
    required String linkKey,
  }) async {
    final normalizedLinkKey = linkKey.trim();
    if (normalizedLinkKey.isEmpty) {
      _showDialogSnackBar('연결된 내신 셀만 과제로 추가할 수 있습니다.');
      return;
    }
    final parsedLink = NaesinExamContext.parseNaesinLinkKey(normalizedLinkKey);
    if (parsedLink == null) {
      _showDialogSnackBar('내신 셀 연결 정보를 확인하지 못했습니다.');
      return;
    }
    final draftLinkKey = '$_kNaesinDraftLinkPrefix|$normalizedLinkKey';
    if (_naesinStandaloneMode && _draftGroupItems.isNotEmpty) {
      setState(() {
        _draftGroupItems.clear();
        _showGroupPanel = false;
      });
    }
    if (_draftGroupItems.isNotEmpty) {
      final firstDraftKey = (_draftGroupItems.first.linkedBookKey ?? '').trim();
      if (_hasNaesinDraftItems()) {
        if (firstDraftKey != draftLinkKey) {
          _showDialogSnackBar('같은 학교/연도 내신 셀로만 묶어 추가할 수 있습니다.');
          return;
        }
      } else {
        _showDialogSnackBar('교재 과제와 내신 과제는 같은 그룹에 섞어 추가할 수 없습니다.');
        return;
      }
    }
    final autoValues = _naesinAutoValuesByCellKey[normalizedLinkKey];
    final pageInput = _page.text.trim();
    final countInput = _parsePositiveIntText(_count.text);
    final autoPageCount = autoValues?.questionPageCount ?? 0;
    final resolvedPage = pageInput.isNotEmpty
        ? pageInput
        : _formatPageRangeFromCount(autoPageCount);
    final resolvedCount = countInput ?? autoValues?.questionCount;
    if (resolvedPage.isEmpty || resolvedCount == null || resolvedCount <= 0) {
      _showDialogSnackBar('연결된 프리셋에서 페이지/문항수를 자동 추출하지 못했습니다.');
      return;
    }
    final autoResolvedTimeLimit =
        _parsePositiveIntText(_timeLimitMinutes.text) ??
            autoValues?.timeLimitMinutes;
    const resolvedType = '프린트';
    final autoTitle = _naesinChildHomeworkTitle();
    final groupTitle = _naesinGroupTitleForCell(school: school, year: year);
    final countText = '$resolvedCount';
    final autoContent = <String>[
      '내신 기출',
      '학교: $school',
      '연도: $year',
      '학년: ${_naesinGradeYearLabel(_naesinGradeKey)}',
      '과정: ${_naesinCourseLabel(_naesinCourseKey)}',
      '시험: $_naesinExamTerm',
      if (parsedLink.cellLabel.isNotEmpty) '셀: ${parsedLink.cellLabel}',
    ].join('\n');

    // 자동 추출값은 가운데 입력필드에도 반영해 사용자가 즉시 수정할 수 있게 한다.
    if (_title.text.trim().isEmpty) {
      _setControllerText(_title, autoTitle);
    }
    if (_page.text.trim().isEmpty) {
      _setControllerText(_page, resolvedPage);
    }
    if (_count.text.trim().isEmpty) {
      _setControllerText(_count, countText);
    }
    if (_timeLimitMinutes.text.trim().isEmpty &&
        autoResolvedTimeLimit != null) {
      _setControllerText(_timeLimitMinutes, '$autoResolvedTimeLimit');
    }
    if (_content.text.trim().isEmpty) {
      _setControllerText(_content, autoContent);
    }

    final titleInput = _title.text.trim();
    final title = titleInput.isEmpty ? autoTitle : titleInput;
    final page = _page.text.trim();
    final count = _parsePositiveIntText(_count.text) ?? resolvedCount;
    if (page.isEmpty || count <= 0) {
      _showDialogSnackBar('페이지/문항수를 확인해주세요.');
      return;
    }
    final countInputText = '$count';
    final timeLimitMinutes =
        _parsePositiveIntText(_timeLimitMinutes.text) ?? autoResolvedTimeLimit;
    final memo = _memo.text.trim();
    final contentInput = _content.text.trim();
    final content = contentInput.isEmpty ? autoContent : contentInput;
    final body = _composeBodyValues(
      page: page,
      count: countInputText,
      content: content,
      timeLimitMinutes: timeLimitMinutes,
    );
    final draftItem = _DraftGroupItem(
      key: 'draft_${_draftGroupItemSeq++}',
      type: resolvedType,
      linkedBookKey: draftLinkKey,
      bookId: '',
      gradeLabel: '',
      sourceUnitLevel: 'naesin',
      sourceUnitPath: normalizedLinkKey,
      unitMappings: const <Map<String, dynamic>>[],
      title: title,
      page: page,
      count: countInputText,
      memo: memo,
      content: content,
      body: body,
      color: _colorForType(resolvedType),
      splitParts: _defaultSplitParts,
      timeLimitMinutes: timeLimitMinutes,
      testMode: true,
      testOriginFlowId: _currentTestOriginFlowId(),
      pbPresetId: autoValues?.presetId,
      naesinLinkKey: normalizedLinkKey,
      naesinGroupTitle: groupTitle,
    );
    if (_naesinStandaloneMode) {
      final compactPage = _normalizePageTextCompact(draftItem.page);
      final outputItem = compactPage == draftItem.page
          ? draftItem
          : draftItem.copyWith(
              page: compactPage,
              body: _composeBodyValues(
                page: compactPage,
                count: draftItem.count,
                content: draftItem.content,
                timeLimitMinutes: draftItem.timeLimitMinutes,
              ),
            );
      Navigator.pop(context, {
        'studentId': widget.studentId,
        'groupMode': true,
        'groupTitle': groupTitle,
        'flowId': _flowId,
        'action': 'add',
        'items': [outputItem.toJson()],
      });
      return;
    }
    setState(() {
      _draftGroupItems.add(draftItem);
      _showGroupPanel = true;
      _applyDraftBlockedStateToUnits(
        _units,
        usedPages: _draftUsedPages(),
      );
    });
    if (!_isChildAddMode && !_groupTitleManuallyEdited) {
      _setGroupTitleText(groupTitle);
    }
  }

  List<_LinkedTextbook> _parseFlowLinkedTextbooks({
    required List<dynamic> rows,
    required String flowId,
    required String flowName,
  }) {
    final links = <_LinkedTextbook>[];
    for (final raw in rows) {
      if (raw is! Map) continue;
      final row = Map<String, dynamic>.from(raw);
      final bookId = (row['book_id'] as String?)?.trim() ?? '';
      final gradeLabel = (row['grade_label'] as String?)?.trim() ?? '';
      if (bookId.isEmpty || gradeLabel.isEmpty) continue;
      links.add(
        _LinkedTextbook(
          flowId: flowId,
          flowName: flowName,
          bookId: bookId,
          gradeLabel: gradeLabel,
          bookName: (row['book_name'] as String?)?.trim() ?? '(이름 없음)',
          orderIndex: (row['order_index'] as int?) ?? links.length,
          migrationStatus:
              (row['migration_status'] as String?)?.trim() ?? 'legacy',
        ),
      );
    }
    links.sort((a, b) {
      if (a.orderIndex != b.orderIndex)
        return a.orderIndex.compareTo(b.orderIndex);
      return a.label.compareTo(b.label);
    });
    return links;
  }

  int _flowOrder(String flowId) {
    for (final flow in widget.flows) {
      if (flow.id == flowId) return flow.orderIndex;
    }
    return 1 << 20;
  }

  Student? get _student {
    for (final entry in DataManager.instance.students) {
      if (entry.student.id == widget.studentId) return entry.student;
    }
    return null;
  }

  int? _gradeOrdinalFromLabel(String raw) {
    final label = raw.replaceAll(' ', '');
    final student = _student;
    final match = RegExp(r'([1-6])').firstMatch(label);
    final grade = int.tryParse(match?.group(1) ?? '');
    if (grade == null) return null;
    if (label.contains('초')) return grade;
    if (label.contains('중')) return 6 + grade;
    if (label.contains('고') ||
        label.contains('공통수학') ||
        label.contains('수학I') ||
        label.contains('수학Ⅱ')) {
      return 9 + grade.clamp(1, 3);
    }
    if (student == null) return null;
    return switch (student.educationLevel) {
      EducationLevel.elementary => grade,
      EducationLevel.middle => 6 + grade.clamp(1, 3),
      EducationLevel.high => 9 + grade.clamp(1, 3),
    };
  }

  bool _isTextbookActive(_LinkedTextbook link) =>
      _textbookActiveOverrides[link.key] ?? true;

  Future<void> _loadAllFlowLinkedBooks() async {
    if (!mounted) return;
    setState(() => _loadingAllFlowTextbooks = true);
    try {
      final flowIds = widget.flows
          .map((flow) => flow.id.trim())
          .where((id) => id.isNotEmpty)
          .toList(growable: false);
      final rowsFuture =
          DataManager.instance.loadFlowTextbookLinksForFlows(flowIds);
      final overridesFuture =
          StudentTextbookActiveStore.instance.loadForStudent(widget.studentId);
      final rows = await rowsFuture;
      Map<String, bool> activeOverrides = const <String, bool>{};
      try {
        activeOverrides = await overridesFuture;
      } catch (_) {
        // 설정 행이 없거나 조회가 실패하면 기존 기본값(활성)으로 동작한다.
      }
      if (!mounted) return;

      final out = <_LinkedTextbook>[];
      for (final flow in widget.flows) {
        out.addAll(
          _parseFlowLinkedTextbooks(
            rows: rows
                .where((row) => '${row['flow_id'] ?? ''}'.trim() == flow.id)
                .toList(growable: false),
            flowId: flow.id,
            flowName: flow.name,
          ),
        );
      }
      if (!mounted) return;
      out.sort((a, b) {
        final aGrade = _gradeOrdinalFromLabel(a.gradeLabel) ?? (1 << 20);
        final bGrade = _gradeOrdinalFromLabel(b.gradeLabel) ?? (1 << 20);
        final byGrade = aGrade.compareTo(bGrade);
        if (byGrade != 0) return byGrade;
        final byLabel = a.gradeLabel.compareTo(b.gradeLabel);
        if (byLabel != 0) return byLabel;
        final byFlow = _flowOrder(a.flowId).compareTo(_flowOrder(b.flowId));
        if (byFlow != 0) return byFlow;
        if (a.orderIndex != b.orderIndex)
          return a.orderIndex.compareTo(b.orderIndex);
        return a.label.compareTo(b.label);
      });
      setState(() {
        _allLinkedTextbooks = out;
        _textbookActiveOverrides = activeOverrides;
      });
      await _handleFlowChanged(
        preferredLinkedBookKey:
            _isChildAddMode ? _lockedLinkedBookKeyForFlow(_flowId) : null,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _allLinkedTextbooks = const <_LinkedTextbook>[];
        _linkedTextbooks = const <_LinkedTextbook>[];
      });
    } finally {
      if (mounted) {
        setState(() => _loadingAllFlowTextbooks = false);
      }
    }
  }

  Future<void> _handleFlowChanged({
    String? preferredLinkedBookKey,
    bool forceNoBookSelection = false,
  }) async {
    final lockedKeyForFlow =
        _isChildAddMode ? _lockedLinkedBookKeyForFlow(_flowId) : null;
    if (_flowId.isEmpty) {
      _disposeMigratedExplorer();
      if (!mounted) return;
      setState(() {
        _linkedTextbooks = const <_LinkedTextbook>[];
        _selectedLinkedBookKey = null;
        _units = const <_BigUnitSelectionNode>[];
        _activeMidKey = null;
        _pendingScrollSmallExpandKey = null;
        _expandedLeftMidSmallsKey = null;
        _manualPageMode = false;
        _rangePickerMode = 'page';
        _selectedProblemRegionIds.clear();
      });
      _refreshRangeAutoDraft();
      return;
    }
    setState(() {
      _loadingFlowTextbooks = true;
      _loadingMetadata = false;
      _linkedTextbooks = const <_LinkedTextbook>[];
      if (_isChildAddMode) {
        _selectedLinkedBookKey = lockedKeyForFlow;
      } else if (forceNoBookSelection) {
        _selectedLinkedBookKey = null;
      } else if (preferredLinkedBookKey != null) {
        _selectedLinkedBookKey = preferredLinkedBookKey;
      }
      _units = const <_BigUnitSelectionNode>[];
      _activeMidKey = null;
      _pendingScrollSmallExpandKey = null;
      _expandedLeftMidSmallsKey = null;
      _manualPageMode = false;
      _rangePickerMode = 'page';
      _selectedProblemRegionIds.clear();
    });
    try {
      // 전체 플로우 일괄 조회 결과에서 현재 플로우만 즉시 전환한다.
      // 플로우 변경 때마다 서버를 다시 호출하지 않는다.
      final links = _allLinkedTextbooks
          .where(
            (link) => _isTestFlowId(_flowId)
                ? _looksLikeWonriBook(link)
                : link.flowId == _flowId,
          )
          .toList(growable: false);
      final preserveKey = _isChildAddMode
          ? lockedKeyForFlow
          : (preferredLinkedBookKey ?? _selectedLinkedBookKey);
      final hasPreserveKey =
          preserveKey != null && links.any((e) => e.key == preserveKey);
      final nextSelectedKey = _isChildAddMode
          ? (hasPreserveKey ? preserveKey : null)
          : (forceNoBookSelection
              ? null
              : (hasPreserveKey ? preserveKey : null));
      setState(() {
        _linkedTextbooks = links;
        _selectedLinkedBookKey = nextSelectedKey;
      });
      if (nextSelectedKey != null) {
        await _loadMetadataForSelectedBook();
      } else {
        _disposeMigratedExplorer();
        if (mounted) {
          setState(() {
            _units = const <_BigUnitSelectionNode>[];
            _activeMidKey = null;
            _pendingScrollSmallExpandKey = null;
            _expandedLeftMidSmallsKey = null;
          });
        }
        _refreshRangeAutoDraft();
      }
    } catch (_) {
      _disposeMigratedExplorer();
      if (!mounted) return;
      setState(() {
        _linkedTextbooks = const <_LinkedTextbook>[];
        _selectedLinkedBookKey = null;
        _units = const <_BigUnitSelectionNode>[];
        _activeMidKey = null;
        _pendingScrollSmallExpandKey = null;
        _expandedLeftMidSmallsKey = null;
      });
      _refreshRangeAutoDraft();
    } finally {
      if (mounted) {
        setState(() => _loadingFlowTextbooks = false);
      }
    }
  }

  Future<void> _loadMetadataForSelectedBook() async {
    final linked = _selectedLinkedBook;
    if (linked == null) {
      _disposeMigratedExplorer();
      if (!mounted) return;
      setState(() {
        _units = const <_BigUnitSelectionNode>[];
        _problemRegions = const <_TextbookProblemRegion>[];
        _selectedProblemRegionIds.clear();
        _linkedBookSeriesKey = null;
        _rangePickerMode = 'page';
        _activeMidKey = null;
        _activeTypeSmallKey = null;
        _pendingScrollSmallExpandKey = null;
        _expandedLeftMidSmallsKey = null;
      });
      _refreshRangeAutoDraft();
      return;
    }
    if (linked.isMigrated) {
      await _loadMigratedBookFast(linked);
      return;
    }
    _disposeMigratedExplorer();
    setState(() => _loadingMetadata = true);
    try {
      final results = await Future.wait<Object?>([
        DataManager.instance.loadTextbookMetadataPayload(
          bookId: linked.bookId,
          gradeLabel: linked.gradeLabel,
        ),
        DataManager.instance.loadTextbookProblemRegions(
          bookId: linked.bookId,
          gradeLabel: linked.gradeLabel,
        ),
      ]);
      if (!mounted || _selectedLinkedBook?.key != linked.key) return;
      final row = results[0] as Map<String, dynamic>?;
      final problemRows = (results[1] as List<Map<String, dynamic>>?) ??
          const <Map<String, dynamic>>[];
      final payload = row?['payload'];
      final seriesKey = payload is Map
          ? '${payload['series'] ?? ''}'.trim().toLowerCase()
          : '';
      final parsed = _parseSelectionUnits(payload);
      final problemRegions = _parseTextbookProblemRegions(problemRows);
      _applyProblemRegionCountsToUnits(parsed, problemRegions);
      // 트리를 먼저 그린 뒤 출제 잠금 상태는 백그라운드 보강.
      _applyDraftBlockedStateToUnits(
        parsed,
        usedPages: _draftUsedPages(),
      );
      setState(() {
        _units = parsed;
        _problemRegions = problemRegions;
        _selectedProblemRegionIds.clear();
        _linkedBookSeriesKey = seriesKey.isEmpty ? null : seriesKey;
        _activeMidKey = _firstActiveMidKey(parsed);
        _activeTypeSmallKey = null;
        _pendingScrollSmallExpandKey = null;
        _expandedLeftMidSmallsKey = null;
        _loadingMetadata = false;
      });
      _refreshRangeAutoDraft();
      unawaited(_applyIssuedStateForLinkedBook(linked, parsed));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _units = const <_BigUnitSelectionNode>[];
        _problemRegions = const <_TextbookProblemRegion>[];
        _selectedProblemRegionIds.clear();
        _linkedBookSeriesKey = null;
        _rangePickerMode = 'page';
        _activeMidKey = null;
        _activeTypeSmallKey = null;
        _pendingScrollSmallExpandKey = null;
        _expandedLeftMidSmallsKey = null;
        _loadingMetadata = false;
      });
      _refreshRangeAutoDraft();
    }
  }

  /// 마이그레이션 교재: explorer를 즉시 띄우고, 중복 metadata/crops·숙제 전체로드로
  /// 트리를 막지 않는다.
  Future<void> _loadMigratedBookFast(_LinkedTextbook linked) async {
    if (!mounted) return;

    final reuseExplorer =
        _migratedExplorerBookKey == linked.key && _migratedExplorer != null;
    TextbookExplorerController? controller = _migratedExplorer;
    if (!reuseExplorer) {
      _disposeMigratedExplorer();
      String academyId = '';
      try {
        academyId = await TenantService.instance.getActiveAcademyId() ?? '';
      } catch (_) {}
      if (!mounted || _selectedLinkedBook?.key != linked.key) return;
      controller = TextbookExplorerController(
        academyId: academyId,
        bookId: linked.bookId,
        gradeLabel: linked.gradeLabel,
        bookTitle: linked.bookName,
        categoryLabel: '교재',
        homeworkSelectionMode: true,
        autoSelectAllQuestionsOnRangeChange: true,
      );
      controller.onClose = () {
        unawaited(_clearSelectedLinkedBook());
      };
      controller.addListener(_syncMigratedExplorerSelection);
      setState(() {
        _loadingMetadata = false;
        _migratedExplorer = controller;
        _migratedExplorerBookKey = linked.key;
        _units = const <_BigUnitSelectionNode>[];
        _rangePickerMode = 'type';
        _selectedProblemRegionIds.clear();
        _activeMidKey = null;
        _activeTypeSmallKey = null;
        _pendingScrollSmallExpandKey = null;
        _expandedLeftMidSmallsKey = null;
      });
    } else {
      controller?.onClose = () {
        unawaited(_clearSelectedLinkedBook());
      };
      setState(() {
        _loadingMetadata = false;
        _rangePickerMode = 'type';
      });
    }

    unawaited(() async {
      try {
        await HomeworkStore.instance.loadAll();
      } catch (_) {}
    }());

    // 코어(메타+크롭) 완료 시 트리 표시. enrich는 controller 내부 백그라운드.
    // crops는 explorer loadCore가 이미 가져오므로 별도 regions fetch는 하지 않는다.
    if (controller != null &&
        (controller.loading || controller.data.units.isEmpty)) {
      await controller.load();
    }
    if (!mounted || _selectedLinkedBook?.key != linked.key) return;
    final seriesKey = TextbookExplorerService.instance.seriesKeyOf(
      bookId: linked.bookId,
      gradeLabel: linked.gradeLabel,
    );
    if (mounted) {
      setState(() {
        _linkedBookSeriesKey = seriesKey.isEmpty ? null : seriesKey;
      });
    }
    _rebuildProblemRegionsFromExplorer();
    _syncMigratedExplorerSelection();
    await _applyMigratedHomeworkIssueStats();
    _refreshRangeAutoDraft();
  }

  /// 마이그레이션 교재 explorer 단원 트리에 내준/완료 횟수를 반영한다.
  Future<void> _applyMigratedHomeworkIssueStats() async {
    try {
      await HomeworkStore.instance.loadAll();
    } catch (_) {}
    if (!mounted) return;
    _syncMigratedHomeworkIssueStatsFromStore();
  }

  void _syncMigratedHomeworkIssueStatsFromStore() {
    final controller = _migratedExplorer;
    final linked = _selectedLinkedBook;
    if (controller == null || linked == null || !linked.isMigrated) return;
    if (controller.data.units.isEmpty) {
      controller.setHomeworkIssueStats();
      return;
    }

    // cropId → 트리 위치. 문항·쪽만 센 뒤, 소단원은 문항 있는 쪽을 모두
    // 덮은 회차만 올린다. sub_key/중단원 폴백으로 빈 쪽까지 1/1 찍지 않는다.
    final cropToPageKey = <String, String>{};
    final cropToSmallKey = <String, String>{};
    final pageKeysByDisplay = <int, Set<String>>{};
    final smallToMid = <String, String>{};
    final smallToBig = <String, String>{};
    final questionPageKeysBySmall = <String, List<String>>{};

    for (final big in controller.data.units) {
      final bigKey = TextbookExplorerController.unitBigKey(big);
      for (final mid in big.mids) {
        final midKey = TextbookExplorerController.unitMidKey(big, mid);
        for (final small in mid.smalls) {
          smallToMid[small.key] = midKey;
          smallToBig[small.key] = bigKey;
          final questionKeys = <String>[];
          for (final page in small.pages) {
            final display = page.displayPage ?? page.rawPage;
            final pageKey = '${small.key}#${page.rawPage}';
            pageKeysByDisplay
                .putIfAbsent(display, () => <String>{})
                .add(pageKey);
            if (!page.isConceptPage) questionKeys.add(pageKey);
          }
          questionPageKeysBySmall[small.key] = questionKeys;
          for (final item in small.items) {
            final cropId = item.cropId.trim();
            if (cropId.isEmpty) continue;
            final pageKey = '${small.key}#${item.rawPage}';
            cropToPageKey[cropId] = pageKey;
            cropToSmallKey[cropId] = small.key;
          }
        }
      }
    }

    final cropAssigned = <String, int>{};
    final cropCompleted = <String, int>{};
    // crop id가 탐색 트리와 안 맞을 때: 과제 page 텍스트·매핑 쪽만 그룹당 1회.
    final fallbackPageAssigned = <String, int>{};
    final fallbackPageCompleted = <String, int>{};

    void bump(Map<String, int> map, String key) {
      map[key] = (map[key] ?? 0) + 1;
    }

    final items = HomeworkStore.instance.items(widget.studentId);
    for (final hw in items) {
      final hwBookId = (hw.bookId ?? '').trim();
      final hwGrade = (hw.gradeLabel ?? '').trim();
      if (hwBookId != linked.bookId || hwGrade != linked.gradeLabel) continue;
      final completed = _isCompletedForIssuedLock(hw);
      final cropIds = _cropIdsFromHomework(hw);
      var matchedCrop = false;
      if (cropIds.isNotEmpty) {
        for (final cropId in cropIds) {
          if (!cropToSmallKey.containsKey(cropId) &&
              !cropToPageKey.containsKey(cropId)) {
            continue;
          }
          matchedCrop = true;
          bump(cropAssigned, cropId);
          if (completed) bump(cropCompleted, cropId);
        }
        if (matchedCrop) continue;
      }

      final eventKey =
          (HomeworkStore.instance.groupIdOfItem(hw.id) ?? hw.id).trim();
      if (eventKey.isEmpty) continue;

      final pagesHw = _displayPagesFromHomework(hw);
      if (pagesHw.isEmpty) continue;
      final touchedPageKeys = <String>{};
      for (final display in pagesHw) {
        final keys = pageKeysByDisplay[display];
        if (keys == null) continue;
        touchedPageKeys.addAll(keys);
      }
      // 그룹 내 소과제들이 같은 페이지를 중복으로 세지 않도록 event당 1회.
      for (final pageKey in touchedPageKeys) {
        final stampKey = '$pageKey@$eventKey';
        if (fallbackPageAssigned.containsKey(stampKey)) continue;
        fallbackPageAssigned[stampKey] = 1;
        if (completed) fallbackPageCompleted[stampKey] = 1;
      }
    }

    int maxOf(Iterable<int> values) {
      var m = 0;
      for (final v in values) {
        if (v > m) m = v;
      }
      return m;
    }

    int minOf(Iterable<int> values) {
      var m = 0;
      var started = false;
      for (final v in values) {
        if (!started || v < m) {
          m = v;
          started = true;
        }
      }
      return started ? m : 0;
    }

    void takeMax(Map<String, int> target, String key, int value) {
      if (value > (target[key] ?? 0)) target[key] = value;
    }

    final pageAssigned = <String, int>{};
    final pageCompleted = <String, int>{};
    final cropsByPage = <String, List<String>>{};
    for (final e in cropToPageKey.entries) {
      cropsByPage.putIfAbsent(e.value, () => <String>[]).add(e.key);
    }
    for (final e in cropsByPage.entries) {
      final a = maxOf(e.value.map((id) => cropAssigned[id] ?? 0));
      final c = maxOf(e.value.map((id) => cropCompleted[id] ?? 0));
      if (a > 0) pageAssigned[e.key] = a;
      if (c > 0) pageCompleted[e.key] = c;
    }
    for (final e in fallbackPageAssigned.entries) {
      final pageKey = e.key.split('@').first;
      pageAssigned[pageKey] = (pageAssigned[pageKey] ?? 0) + e.value;
    }
    for (final e in fallbackPageCompleted.entries) {
      final pageKey = e.key.split('@').first;
      pageCompleted[pageKey] = (pageCompleted[pageKey] ?? 0) + e.value;
    }

    final cropsBySmall = <String, List<String>>{};
    for (final e in cropToSmallKey.entries) {
      cropsBySmall.putIfAbsent(e.value, () => <String>[]).add(e.key);
    }
    final smallAssigned = <String, int>{};
    final smallCompleted = <String, int>{};
    for (final e in questionPageKeysBySmall.entries) {
      final smallKey = e.key;
      final questionKeys = e.value;
      if (questionKeys.isEmpty) {
        final cropIds = cropsBySmall[smallKey];
        if (cropIds == null || cropIds.isEmpty) continue;
        final a = maxOf(cropIds.map((id) => cropAssigned[id] ?? 0));
        final c = maxOf(cropIds.map((id) => cropCompleted[id] ?? 0));
        if (a > 0) smallAssigned[smallKey] = a;
        if (c > 0) smallCompleted[smallKey] = c;
        continue;
      }
      final minA = minOf(questionKeys.map((k) => pageAssigned[k] ?? 0));
      final minC = minOf(questionKeys.map((k) => pageCompleted[k] ?? 0));
      if (minA > 0) smallAssigned[smallKey] = minA;
      if (minC > 0) smallCompleted[smallKey] = minC;
    }

    final midAssigned = <String, int>{};
    final midCompleted = <String, int>{};
    final bigAssigned = <String, int>{};
    final bigCompleted = <String, int>{};
    for (final e in smallAssigned.entries) {
      final midKey = smallToMid[e.key];
      final bigKey = smallToBig[e.key];
      if (midKey != null) takeMax(midAssigned, midKey, e.value);
      if (bigKey != null) takeMax(bigAssigned, bigKey, e.value);
    }
    for (final e in smallCompleted.entries) {
      final midKey = smallToMid[e.key];
      final bigKey = smallToBig[e.key];
      if (midKey != null) takeMax(midCompleted, midKey, e.value);
      if (bigKey != null) takeMax(bigCompleted, bigKey, e.value);
    }

    controller.setHomeworkIssueStats(
      pageAssigned: pageAssigned,
      pageCompleted: pageCompleted,
      smallAssigned: smallAssigned,
      smallCompleted: smallCompleted,
      midAssigned: midAssigned,
      midCompleted: midCompleted,
      bigAssigned: bigAssigned,
      bigCompleted: bigCompleted,
    );
  }

  Set<String> _cropIdsFromHomework(HomeworkItem hw) {
    final out = <String>{};
    final mappings = hw.unitMappings;
    if (mappings == null || mappings.isEmpty) return out;
    for (final raw in mappings) {
      final crops = raw['problemCrops'] ?? raw['problem_crops'];
      if (crops is! List) continue;
      for (final crop in crops) {
        if (crop is! Map) continue;
        final id = '${crop['cropId'] ?? crop['crop_id'] ?? ''}'.trim();
        if (id.isNotEmpty) out.add(id);
      }
    }
    return out;
  }

  /// 과제 page 텍스트·unitMappings에서 실제로 내준 표시 쪽을 수집한다.
  /// pageCounts/문항이 있으면 start~end 구간을 채우지 않는다(빈 쪽 오탐 방지).
  Set<int> _displayPagesFromHomework(HomeworkItem hw) {
    final fromText = _pagesFromRawPageText(hw.page ?? '');
    if (fromText.isNotEmpty) return fromText;

    final pages = <int>{};
    final mappings = hw.unitMappings;
    if (mappings == null || mappings.isEmpty) return pages;
    var hasExplicitPages = false;
    for (final raw in mappings) {
      final m = Map<String, dynamic>.from(raw);
      final pageCounts = m['pageCounts'] ?? m['page_counts'];
      if (pageCounts is Map) {
        for (final key in pageCounts.keys) {
          final page = _toInt(key);
          if (page == null || page <= 0) continue;
          pages.add(page);
          hasExplicitPages = true;
        }
      }
      final crops = m['problemCrops'] ?? m['problem_crops'];
      if (crops is! List) continue;
      for (final crop in crops) {
        if (crop is! Map) continue;
        final page = _toInt(
          crop['displayPage'] ??
              crop['display_page'] ??
              crop['rawPage'] ??
              crop['raw_page'],
        );
        if (page == null || page <= 0) continue;
        pages.add(page);
        hasExplicitPages = true;
      }
    }
    if (hasExplicitPages) return pages;
    for (final raw in mappings) {
      final m = Map<String, dynamic>.from(raw);
      _addPageRange(
        pages,
        _toInt(m['startPage'] ?? m['start_page']),
        _toInt(m['endPage'] ?? m['end_page']),
      );
    }
    return pages;
  }

  void _rebuildProblemRegionsFromExplorer() {
    final controller = _migratedExplorer;
    if (controller == null || controller.loading) return;
    final next = _problemRegionsFromExplorer(controller);
    _problemRegions = next;
  }

  List<_TextbookProblemRegion> _problemRegionsFromExplorer(
    TextbookExplorerController controller,
  ) {
    final out = <_TextbookProblemRegion>[];
    List<int>? to1k(
      double? xmin,
      double? ymin,
      double? xmax,
      double? ymax,
    ) {
      if (xmin == null || ymin == null || xmax == null || ymax == null) {
        return null;
      }
      if (!(xmax > xmin && ymax > ymin)) return null;
      return <int>[
        (ymin * 1000).round().clamp(0, 1000),
        (xmin * 1000).round().clamp(0, 1000),
        (ymax * 1000).round().clamp(0, 1000),
        (xmax * 1000).round().clamp(0, 1000),
      ];
    }

    for (final big in controller.data.units) {
      for (final mid in big.mids) {
        for (final small in mid.smalls) {
          for (final item in small.items) {
            if (item.cropId.trim().isEmpty) continue;
            out.add(
              _TextbookProblemRegion(
                id: item.cropId,
                bigOrder: item.bigOrder,
                midOrder: item.midOrder,
                subKey: item.subKey,
                subIndex: item.subIndex,
                bigName: big.name,
                midName: mid.name,
                smallName: small.name,
                rawPage: item.rawPage > 0 ? item.rawPage : null,
                displayPage: item.displayPage ?? item.rawPage,
                problemNumber: item.problemNumber,
                label: item.difficultyLabel,
                section: item.section,
                isSetHeader: item.isSetHeader,
                isWonri: item.isWonri,
                pbQuestionUid: item.questionUid,
                typeKind: item.typeGroupKind,
                typeLabel: item.typeGroupLabel,
                typeTitle: item.typeGroupTitle,
                typeOrder: null,
                columnIndex: 0,
                bbox1k: to1k(
                  item.numberXmin,
                  item.numberYmin,
                  item.numberXmax,
                  item.numberYmax,
                ),
                itemRegion1k: to1k(
                  item.xmin,
                  item.ymin,
                  item.xmax,
                  item.ymax,
                ),
              ),
            );
          }
        }
      }
    }
    return out;
  }

  Future<void> _applyIssuedStateForLinkedBook(
    _LinkedTextbook linked,
    List<_BigUnitSelectionNode> units,
  ) async {
    try {
      await HomeworkStore.instance.loadAll();
    } catch (_) {}
    if (!mounted || _selectedLinkedBook?.key != linked.key) return;
    final issuedSummaryBySmallKey = _issuedSmallSummaryByBook(
      bookId: linked.bookId,
      gradeLabel: linked.gradeLabel,
      units: units,
    );
    final pageCounts = _issuedPageCountsByBook(
      bookId: linked.bookId,
      gradeLabel: linked.gradeLabel,
      units: units,
    );
    final acknowledgedSmallKeys =
        await _loadAcknowledgedSmallKeysForLinkedBook(linked);
    if (!mounted || _selectedLinkedBook?.key != linked.key) return;
    _applyIssuedLockedState(
      units,
      issuedSummaryBySmallKey,
      acknowledgedSmallKeys,
      pageCounts.completed,
      pageCounts.assigned,
    );
    _applyDraftBlockedStateToUnits(
      units,
      usedPages: _draftUsedPages(),
    );
    if (mounted) setState(() {});
  }

  void _syncMigratedExplorerSelection() {
    final controller = _migratedExplorer;
    if (!mounted || controller == null) return;
    var regionsTouched = false;
    // enrich로 uid가 채워져도 draft 매핑이 따라가도록 explorer 기준으로 재구성.
    if (!controller.loading && controller.data.units.isNotEmpty) {
      final prevCount = _problemRegions.length;
      final prevUid =
          _problemRegions.isEmpty ? '' : _problemRegions.first.pbQuestionUid;
      _rebuildProblemRegionsFromExplorer();
      regionsTouched = prevCount != _problemRegions.length ||
          prevUid !=
              (_problemRegions.isEmpty
                  ? ''
                  : _problemRegions.first.pbQuestionUid);
    }
    final next = <String>{};
    for (final item in controller.selectedItems) {
      final cropId = item.cropId.trim();
      if (cropId.isNotEmpty) {
        next.add(cropId);
        continue;
      }
      for (final region in _problemRegions) {
        final itemUid = item.questionUid.trim();
        final regionUid = region.pbQuestionUid.trim();
        final uidMatches =
            itemUid.isNotEmpty && regionUid.isNotEmpty && itemUid == regionUid;
        final locationMatches = itemUid.isEmpty &&
            region.bigOrder == item.bigOrder &&
            region.midOrder == item.midOrder &&
            region.subKey == item.subKey &&
            region.rawPage == item.rawPage &&
            region.problemNumber == item.problemNumber;
        if (uidMatches || locationMatches) {
          next.add(region.id);
          break;
        }
      }
    }
    final selectionChanged = next.length != _selectedProblemRegionIds.length ||
        !next.every(_selectedProblemRegionIds.contains);
    final conceptPageKeys = _selectedMigratedConceptPages()
        .map((e) => '${e.smallKey}#${e.rawPage}')
        .toList()
      ..sort();
    final conceptFingerprint = conceptPageKeys.join(',');
    final conceptSelectionChanged =
        conceptFingerprint != _migratedConceptPageSelectionFingerprint;
    // enrich로 페이지/소단원이 늘어나도 내준·완료 배지가 따라가도록 재집계.
    _syncMigratedHomeworkIssueStatsFromStore();
    if (!selectionChanged && !conceptSelectionChanged && !regionsTouched) {
      return;
    }
    setState(() {
      _rangePickerMode = 'type';
      _migratedConceptPageSelectionFingerprint = conceptFingerprint;
      if (selectionChanged) {
        _selectedProblemRegionIds
          ..clear()
          ..addAll(next);
      }
    });
    if (selectionChanged || conceptSelectionChanged) {
      _refreshRangeAutoDraft();
    }
  }

  List<_SelectedMigratedConceptPage> _selectedMigratedConceptPages() {
    final controller = _migratedExplorer;
    final book = _selectedLinkedBook;
    if (controller == null ||
        controller.loading ||
        book == null ||
        (!_isWonriLinkedBook(book) && !_isGaeyuLinkedBook(book))) {
      return const [];
    }
    final out = <_SelectedMigratedConceptPage>[];
    for (final big in controller.data.units) {
      for (final mid in big.mids) {
        for (final small in mid.smalls) {
          for (final page in small.pages) {
            if (!page.isConceptPage ||
                !controller.checkedPageKeys
                    .contains('${small.key}#${page.rawPage}')) {
              continue;
            }
            out.add((
              bigOrder: big.order,
              bigName: big.name,
              midOrder: mid.order,
              midName: mid.name,
              smallOrder: small.order,
              smallKey: small.key,
              smallName: small.name,
              rawPage: page.rawPage,
              displayPage: page.displayPage ?? page.rawPage,
            ));
          }
        }
      }
    }
    return out;
  }

  List<_BigUnitSelectionNode> _parseSelectionUnits(dynamic payload) {
    if (payload is! Map) return const <_BigUnitSelectionNode>[];
    final unitsRaw = payload['units'];
    if (unitsRaw is! List) return const <_BigUnitSelectionNode>[];
    final List<Map<String, dynamic>> units = unitsRaw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    units.sort((a, b) =>
        _orderIndex(a['order_index']).compareTo(_orderIndex(b['order_index'])));

    final List<_BigUnitSelectionNode> out = <_BigUnitSelectionNode>[];
    for (final u in units) {
      final bigOrder = _orderIndex(u['order_index']);
      final big = _BigUnitSelectionNode(
        name: (u['name'] as String?)?.trim().isNotEmpty == true
            ? (u['name'] as String).trim()
            : '대단원',
        orderIndex: bigOrder,
      );
      final midsRaw = u['middles'];
      if (midsRaw is List) {
        final mids = midsRaw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        mids.sort((a, b) => _orderIndex(a['order_index'])
            .compareTo(_orderIndex(b['order_index'])));
        for (final m in mids) {
          final midOrder = _orderIndex(m['order_index']);
          // 개념서(개념원리)면 sub_units(실제 소단원), 그 외면 smalls.
          final isConcept = midHasSubUnits(m);
          final mid = _MidUnitSelectionNode(
            name: (m['name'] as String?)?.trim().isNotEmpty == true
                ? (m['name'] as String).trim()
                : '중단원',
            orderIndex: midOrder,
            isConcept: isConcept,
          );
          for (final s in displaySubUnitsForMid(m)) {
            final smallOrder = s.order;
            final Map<int, int> pageCounts = <int, int>{};
            final countsRaw = s.raw['page_counts'];
            if (countsRaw is Map) {
              countsRaw.forEach((k, v) {
                final rawPage = _toInt(k);
                final c = _toInt(v);
                if (rawPage == null || c == null) return;
                pageCounts[rawPage] = (pageCounts[rawPage] ?? 0) + c;
              });
            }
            mid.smalls.add(
              _SmallUnitSelectionNode(
                name: s.name,
                orderIndex: smallOrder,
                subKey: s.subKey.isNotEmpty
                    ? s.subKey
                    : _fallbackSubKey('', smallOrder),
                startPage: s.startPage,
                endPage: s.endPage,
                pageCounts: pageCounts,
                locked: false,
                draftBlocked: false,
                finishedAt: null,
                completedCount: 0,
              ),
            );
          }
          big.middles.add(mid);
        }
      }
      out.add(big);
    }
    return out;
  }

  int _orderIndex(dynamic value) => _toInt(value) ?? (1 << 30);

  int? _toInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  String _fallbackSubKey(String raw, int orderIndex) {
    final trimmed = raw.trim();
    if (trimmed.isNotEmpty) return trimmed;
    if (orderIndex >= 0 && orderIndex < 26) {
      return String.fromCharCode('A'.codeUnitAt(0) + orderIndex);
    }
    return '';
  }

  List<_TextbookProblemRegion> _parseTextbookProblemRegions(
    List<Map<String, dynamic>> rows,
  ) {
    final out = <_TextbookProblemRegion>[];
    for (final row in rows) {
      final rawPage = _toInt(row['raw_page']);
      final displayPage = _toInt(row['display_page']) ?? rawPage;
      final problemNumber = '${row['problem_number'] ?? ''}'.trim();
      final id = '${row['id'] ?? ''}'.trim();
      if (displayPage == null || problemNumber.isEmpty) continue;
      final bigOrder = _toInt(row['big_order']) ?? -1;
      final midOrder = _toInt(row['mid_order']) ?? -1;
      final subKey = '${row['sub_key'] ?? ''}'.trim();
      final typeKind = '${row['content_group_kind'] ?? ''}'.trim();
      final typeLabel = '${row['content_group_label'] ?? ''}'.trim();
      final typeTitle = '${row['content_group_title'] ?? ''}'.trim();
      final itemName = '${row['item_name'] ?? ''}'.trim();
      final rawLabel = '${row['label'] ?? ''}'.trim();
      final section = '${row['section'] ?? ''}'.trim();
      final normalizedItem = normalizeWonriItemName(itemName);
      // section 이 개념원리 카테고리이거나 item_name 이 개념원리 유형명일 때만.
      // (쎈도 sub_key A/B/C 를 쓰므로 sub_key 단독으로는 판별하지 않는다.)
      final isWonri = kWonriTypeNameBySection.containsKey(section) ||
          normalizedItem == '개념원리 익히기' ||
          normalizedItem == '필수유형' ||
          normalizedItem == '확인 체크' ||
          normalizedItem == '특강' ||
          normalizedItem == '연습문제' ||
          normalizedItem.startsWith('STEP') ||
          normalizedItem.contains('실력') ||
          normalizedItem.contains('기출');
      // 개념원리는 item_name 에 유형명이 있고 label 은 비어 있는 경우가 많다.
      final displayLabel = isWonri
          ? (normalizedItem.isNotEmpty ? normalizedItem : rawLabel)
          : rawLabel;
      out.add(
        _TextbookProblemRegion(
          id: id.isEmpty
              ? '$bigOrder|$midOrder|$subKey|$displayPage|$problemNumber'
              : id,
          bigOrder: bigOrder,
          midOrder: midOrder,
          subKey: subKey,
          subIndex: _toInt(row['sub_index']) ?? 0,
          bigName: '${row['big_name'] ?? ''}'.trim(),
          midName: '${row['mid_name'] ?? ''}'.trim(),
          smallName: '${row['small_name'] ?? row['sub_name'] ?? ''}'.trim(),
          rawPage: rawPage,
          displayPage: displayPage,
          problemNumber: problemNumber,
          label: displayLabel,
          section: section,
          isSetHeader: row['is_set_header'] == true,
          isWonri: isWonri,
          pbQuestionUid: '${row['pb_question_uid'] ?? ''}'.trim(),
          typeKind: typeKind,
          typeLabel: typeLabel,
          typeTitle: typeTitle,
          typeOrder: _toInt(row['content_group_order']),
          columnIndex: _toInt(row['column_index']) ?? 0,
          bbox1k: row['bbox_1k'],
          itemRegion1k: row['item_region_1k'],
        ),
      );
    }
    out.sort(_compareTextbookProblemRegionsBySource);
    return out;
  }

  void _applyProblemRegionCountsToUnits(
    List<_BigUnitSelectionNode> units,
    List<_TextbookProblemRegion> regions,
  ) {
    if (units.isEmpty || regions.isEmpty) return;
    final countsBySmall = <String, Map<int, int>>{};
    for (final region in regions) {
      if (region.isSetHeader) continue;
      final key = '${region.bigOrder}|${region.midOrder}|${region.subKey}';
      final byPage = countsBySmall.putIfAbsent(key, () => <int, int>{});
      byPage[region.displayPage] = (byPage[region.displayPage] ?? 0) + 1;
    }
    // 개념서는 중단원별 문항 페이지 카운트를 모아 소단원 페이지 범위로 배분.
    final countsByMid = <String, Map<int, int>>{};
    for (final region in regions) {
      if (region.isSetHeader) continue;
      final key = '${region.bigOrder}|${region.midOrder}';
      final byPage = countsByMid.putIfAbsent(key, () => <int, int>{});
      byPage[region.displayPage] = (byPage[region.displayPage] ?? 0) + 1;
    }
    for (final big in units) {
      for (final mid in big.middles) {
        if (mid.isConcept) {
          final byPage = countsByMid['${big.orderIndex}|${mid.orderIndex}'] ??
              const <int, int>{};
          for (final entry in byPage.entries) {
            final page = entry.key;
            for (final small in mid.smalls) {
              final start = small.startPage;
              if (start == null) continue;
              final end = small.endPage ?? start;
              if (page >= start && page <= end) {
                small.pageCounts[page] = entry.value;
                break;
              }
            }
          }
          continue;
        }
        for (final small in mid.smalls) {
          final byPage = countsBySmall[
              '${big.orderIndex}|${mid.orderIndex}|${small.subKey}'];
          if (byPage == null || byPage.isEmpty) continue;
          for (final entry in byPage.entries) {
            small.pageCounts[entry.key] = entry.value;
          }
        }
      }
    }
  }

  String _smallKey(int bigOrder, int midOrder, int smallOrder) {
    return '$bigOrder|$midOrder|$smallOrder';
  }

  String _smallExpandKey(
    _BigUnitSelectionNode big,
    _MidUnitSelectionNode mid,
    _SmallUnitSelectionNode small,
  ) {
    return '${big.orderIndex}|${mid.orderIndex}|${small.orderIndex}';
  }

  String _midExpandKey(_BigUnitSelectionNode big, _MidUnitSelectionNode mid) {
    return 'big:${big.orderIndex}|mid:${mid.orderIndex}';
  }

  String? _firstActiveMidKey(List<_BigUnitSelectionNode> units) {
    for (final big in units) {
      for (final mid in big.middles) {
        return _midExpandKey(big, mid);
      }
    }
    return null;
  }

  MapEntry<_BigUnitSelectionNode, _MidUnitSelectionNode>? _resolveActiveMid() {
    final key = _activeMidKey;
    if (key == null) return null;
    for (final big in _units) {
      for (final mid in big.middles) {
        if (_midExpandKey(big, mid) == key) {
          return MapEntry(big, mid);
        }
      }
    }
    return null;
  }

  GlobalKey _headerKeyForSmallExpand(String expandKey) {
    return _smallHeaderKeys.putIfAbsent(expandKey, GlobalKey.new);
  }

  void _scheduleScrollSmallHeaderToTop(String expandKey) {
    _pendingScrollSmallExpandKey = expandKey;
    final token = expandKey;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_pendingScrollSmallExpandKey != token) return;
      _pendingScrollSmallExpandKey = null;
      final ctx = _smallHeaderKeys[expandKey]?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: 0,
        );
      }
    });
  }

  void _onLeftMidRowTapped(
      _BigUnitSelectionNode big, _MidUnitSelectionNode mid) {
    final midKey = _midExpandKey(big, mid);
    setState(() {
      _activeMidKey = midKey;
      _activeTypeSmallKey = null;
      if (mid.smalls.isNotEmpty) {
        if (_expandedLeftMidSmallsKey == midKey) {
          _expandedLeftMidSmallsKey = null;
        } else {
          _expandedLeftMidSmallsKey = midKey;
        }
      }
    });
  }

  void _onLeftSmallRowTapped(
    _BigUnitSelectionNode big,
    _MidUnitSelectionNode mid,
    _SmallUnitSelectionNode small,
  ) {
    final expand = _smallExpandKey(big, mid, small);
    final midKey = _midExpandKey(big, mid);
    setState(() {
      _activeMidKey = midKey;
      _activeTypeSmallKey =
          _rangePickerMode == 'type' ? _smallExpandKey(big, mid, small) : null;
      if (mid.smalls.isNotEmpty) {
        _expandedLeftMidSmallsKey = midKey;
      }
    });
    _scheduleScrollSmallHeaderToTop(expand);
  }

  String _smallTitlePrefix(
    _BigUnitSelectionNode big,
    _MidUnitSelectionNode mid,
    _SmallUnitSelectionNode small,
  ) {
    return '${_n(big.orderIndex)}.${_n(mid.orderIndex)}.(${_n(small.orderIndex)})';
  }

  String _ackPrefsKeyForLinkedBook(_LinkedTextbook linked) {
    final bookKey = '${linked.bookId}|${linked.gradeLabel}';
    return 'flow_textbook_ack_units_v1:${widget.studentId}|${linked.flowId}|$bookKey';
  }

  Future<Set<String>> _loadAcknowledgedSmallKeysForLinkedBook(
    _LinkedTextbook linked,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final values = prefs.getStringList(_ackPrefsKeyForLinkedBook(linked)) ??
          const <String>[];
      return values.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  void _addPageRange(Set<int> pages, int? a, int? b) {
    if (a == null && b == null) return;
    if (a != null && b != null) {
      int start = a;
      int end = b;
      if (start > end) {
        final temp = start;
        start = end;
        end = temp;
      }
      if (end - start > 1600) {
        if (start > 0) pages.add(start);
        if (end > 0) pages.add(end);
        return;
      }
      for (int p = start; p <= end; p++) {
        if (p > 0) pages.add(p);
      }
      return;
    }
    final single = a ?? b;
    if (single != null && single > 0) {
      pages.add(single);
    }
  }

  Set<int> _pagesFromRawPageText(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return <int>{};
    final normalized = trimmed
        .replaceAll(RegExp(r'p\.', caseSensitive: false), '')
        .replaceAll('페이지', '')
        .replaceAll('쪽', '')
        .replaceAll('~', '-')
        .replaceAll('–', '-')
        .replaceAll('—', '-');
    final tokens = normalized
        .split(RegExp(r'[,/\s]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty);
    final pages = <int>{};
    for (final token in tokens) {
      if (token.contains('-')) {
        final parts = token
            .split('-')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
        if (parts.length != 2) continue;
        _addPageRange(pages, _toInt(parts[0]), _toInt(parts[1]));
      } else {
        final value = _toInt(token);
        if (value != null && value > 0) pages.add(value);
      }
    }
    return pages;
  }

  bool _hasPageOverlap(Set<int> a, Set<int> b) {
    if (a.isEmpty || b.isEmpty) return false;
    final small = a.length <= b.length ? a : b;
    final large = identical(small, a) ? b : a;
    for (final p in small) {
      if (large.contains(p)) return true;
    }
    return false;
  }

  String? _currentDraftBookKey() {
    if (_draftGroupItems.isEmpty) return null;
    final firstKey = _draftGroupItems.first.linkedBookKey;
    for (final item in _draftGroupItems) {
      if (item.linkedBookKey != firstKey) return firstKey;
    }
    return firstKey;
  }

  String? _bookIdentity(_LinkedTextbook? linked) {
    if (linked == null) return null;
    return '${linked.bookId}|${linked.gradeLabel}';
  }

  Set<int> _draftUsedPages({String? excludingDraftKey}) {
    final used = <int>{};
    for (final item in _draftGroupItems) {
      if (excludingDraftKey != null && item.key == excludingDraftKey) continue;
      used.addAll(_pagesFromRawPageText(item.page));
    }
    return used;
  }

  Set<String> _problemIdsFromMappings(List<Map<String, dynamic>> mappings) {
    final out = <String>{};
    for (final mapping in mappings) {
      final crops = mapping['problemCrops'];
      if (crops is! List) continue;
      for (final raw in crops) {
        if (raw is! Map) continue;
        final id = '${raw['cropId'] ?? ''}'.trim();
        if (id.isNotEmpty) out.add(id);
      }
    }
    return out;
  }

  Set<String> _draftUsedProblemIds({String? excludingDraftKey}) {
    final used = <String>{};
    for (final item in _draftGroupItems) {
      if (excludingDraftKey != null && item.key == excludingDraftKey) continue;
      used.addAll(_problemIdsFromMappings(item.unitMappings));
    }
    return used;
  }

  String _pagesToCompactText(Set<int> pages) {
    if (pages.isEmpty) return '';
    final sorted = pages.toList(growable: false)..sort();
    final chunks = <String>[];
    int start = sorted.first;
    int prev = sorted.first;
    for (int i = 1; i < sorted.length; i++) {
      final cur = sorted[i];
      if (cur == prev + 1) {
        prev = cur;
        continue;
      }
      chunks.add(start == prev ? '$start' : '$start-$prev');
      start = cur;
      prev = cur;
    }
    chunks.add(start == prev ? '$start' : '$start-$prev');
    return chunks.join(', ');
  }

  String _normalizePageTextCompact(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    final parsed = _pagesFromRawPageText(trimmed);
    if (parsed.isEmpty) return trimmed;
    final compact = _pagesToCompactText(parsed);
    return compact.isEmpty ? trimmed : compact;
  }

  Set<int> _smallPages(_SmallUnitSelectionNode small) {
    final pages = <int>{...small.pageCounts.keys};
    _addPageRange(pages, small.startPage, small.endPage);
    return pages;
  }

  void _applyDraftBlockedStateToUnits(
    List<_BigUnitSelectionNode> units, {
    required Set<int> usedPages,
  }) {
    for (final big in units) {
      big.explicitSelected = false;
      for (final mid in big.middles) {
        mid.explicitSelected = false;
        for (final small in mid.smalls) {
          final blockedByDraft = usedPages.isNotEmpty &&
              _hasPageOverlap(_smallPages(small), usedPages);
          small.draftBlocked = blockedByDraft;
          if (small.draftBlocked) {
            small.selected = false;
            small.explicitSelected = false;
            small.selectedPages.clear();
          }
        }
        mid.selected = _allSmallSelected(mid);
      }
      big.selected = _allMidSelected(big);
    }
  }

  void _resetRangeSelectionAfterAdd() {
    setState(() {
      for (final big in _units) {
        big.explicitSelected = false;
        for (final mid in big.middles) {
          mid.explicitSelected = false;
          for (final small in mid.smalls) {
            if (small.draftBlocked) continue;
            small.selected = false;
            small.explicitSelected = false;
            small.selectedPages.clear();
          }
          mid.selected = _allSmallSelected(mid);
        }
        big.selected = _allMidSelected(big);
      }
      _selectedProblemRegionIds.clear();
    });
    _refreshRangeAutoDraft();
  }

  String _truncateTitle(String text, int maxChars) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= maxChars) return normalized;
    return normalized.substring(0, maxChars).trimRight();
  }

  void _onGroupTitleEdited() {
    if (_suppressGroupTitleListener || _isChildAddMode) return;
    _groupTitleManuallyEdited = true;
  }

  void _setGroupTitleText(String text) {
    _suppressGroupTitleListener = true;
    _setControllerText(_groupTitle, text);
    _suppressGroupTitleListener = false;
  }

  bool _isWonriLinkedBook(_LinkedTextbook? book) {
    if (book == null) return false;
    final name = book.bookName.trim();
    if (name.contains('개념원리') || name.toLowerCase().contains('wonri')) {
      return true;
    }
    for (final big in _units) {
      for (final mid in big.middles) {
        if (mid.isConcept) return true;
      }
    }
    final controller = _migratedExplorer;
    if (controller == null || controller.loading) return false;
    for (final big in controller.data.units) {
      for (final mid in big.mids) {
        for (final small in mid.smalls) {
          for (final item in small.items) {
            if (item.isWonri) return true;
          }
        }
      }
    }
    return false;
  }

  bool _isSsenLinkedBook(_LinkedTextbook? book) {
    if (book == null) return false;
    final series = (_linkedBookSeriesKey ?? '').trim().toLowerCase();
    if (series == 'ssen') return true;
    final name = book.bookName.trim();
    final lower = name.toLowerCase();
    return name.contains('쎈') || lower.contains('ssen');
  }

  bool _isRpmLinkedBook(_LinkedTextbook? book) {
    if (book == null) return false;
    final series = (_linkedBookSeriesKey ?? '').trim().toLowerCase();
    if (series == 'rpm') return true;
    final name = book.bookName.trim();
    final lower = name.toLowerCase();
    return name.contains('RPM') ||
        name.contains('ＲＰＭ') ||
        lower.contains('rpm');
  }

  bool _isGaeyuLinkedBook(_LinkedTextbook? book) {
    if (book == null) return false;
    final series = (_linkedBookSeriesKey ?? '').trim().toLowerCase();
    if (series == 'gaeyu') return true;
    final compact =
        book.bookName.trim().replaceAll(RegExp(r'[\s+]'), '').toLowerCase();
    return compact.contains('개념유형') ||
        compact.contains('개념플러스유형') ||
        compact.contains('gaeyu');
  }

  /// 쎈·RPM 공통: A/B/C 문제집 (하위과제=유형명, 그룹=중단원+단계).
  bool _isSsenLikeLinkedBook(_LinkedTextbook? book) =>
      _isSsenLinkedBook(book) || _isRpmLinkedBook(book);

  /// 수력충전: 미이관 교재. 그룹과제명만 중단원명으로 둔다.
  bool _isSuryeokLinkedBook(_LinkedTextbook? book) {
    if (book == null) return false;
    final name = book.bookName.trim();
    final compact = name.replaceAll(RegExp(r'\s+'), '');
    return compact.contains('수력충전');
  }

  /// 권장시간 단가 조회용 시리즈 키 (payload series 우선, 없으면 이름 추론).
  String _recommendedTimeSeriesKey(_LinkedTextbook? book) {
    final series = (_linkedBookSeriesKey ?? '').trim().toLowerCase();
    if (series.isNotEmpty) return series;
    if (_isSsenLinkedBook(book)) return 'ssen';
    if (_isRpmLinkedBook(book)) return 'rpm';
    if (_isGaeyuLinkedBook(book)) return 'gaeyu';
    if (_isWonriLinkedBook(book)) return 'wonri';
    if (_isSuryeokLinkedBook(book)) return 'suryeok';
    return '';
  }

  /// 문항 단위 선택(이관 교재)의 권장시간(분). 단가 미설정이면 null.
  int? _estimateRecommendedMinutesForRegions(
    _LinkedTextbook book,
    List<_TextbookProblemRegion> regions,
  ) {
    final series = _recommendedTimeSeriesKey(book);
    final counts = <String, int>{};
    var uncategorized = 0;
    for (final region in regions) {
      if (region.isSetHeader) continue;
      final key = HomeworkTimeDefaultsService.categoryKeyFor(
        seriesKey: series,
        label: region.label,
        section: region.section,
        isWonri: region.isWonri,
        subKey: region.subKey,
      );
      if (key.isEmpty) {
        uncategorized++;
      } else {
        counts[key] = (counts[key] ?? 0) + 1;
      }
    }
    return HomeworkTimeDefaultsService.instance.estimateMinutes(
      seriesKey: series,
      schoolLevelKey: HomeworkTimeDefaultsService.schoolLevelKeyForGradeLabel(
        book.gradeLabel,
      ),
      categoryCounts: counts,
      uncategorizedCount: uncategorized,
    );
  }

  /// 문항 분류 없이 문항수/페이지수만 아는 경우의 권장시간(분).
  int? _estimateRecommendedMinutesForCount(
    _LinkedTextbook? book, {
    int? count,
    String? pageText,
  }) {
    final series = _recommendedTimeSeriesKey(book);
    int? pageCount;
    if ((count == null || count <= 0) &&
        pageText != null &&
        pageText.trim().isNotEmpty) {
      final pages = _pagesFromRawPageText(pageText);
      pageCount = pages.isEmpty ? null : pages.length;
    }
    return HomeworkTimeDefaultsService.instance.estimateMinutes(
      seriesKey: series,
      schoolLevelKey: HomeworkTimeDefaultsService.schoolLevelKeyForGradeLabel(
        book?.gradeLabel ?? '',
      ),
      uncategorizedCount: (count != null && count > 0) ? count : 0,
      pageCount: pageCount,
    );
  }

  String? _ssenStageLetter(String? raw) {
    final text = (raw ?? '').trim().toUpperCase();
    if (text.isEmpty) return null;
    if (text == 'A' || text == 'B' || text == 'C') return text;
    final match = RegExp(r'([ABC])\s*단계').firstMatch(text);
    if (match != null) return match.group(1);
    final head = RegExp(r'^([ABC])\b').firstMatch(text);
    return head?.group(1);
  }

  /// RPM C단계 서술형/실력 UP 섹션명. 해당 없으면 null.
  String? _rpmSpecialSectionTitle(_TextbookProblemRegion region) {
    return problemBookSpecialSectionTitle(region.label);
  }

  String _problemSubtaskGroupKey(
    _TextbookProblemRegion region,
    _LinkedTextbook book,
  ) {
    if (_isRpmLinkedBook(book)) {
      final special = _rpmSpecialSectionTitle(region);
      if (special != null) {
        return '${region.bigOrder}|${region.midOrder}|${region.subKey}|rpm|$special';
      }
    }
    return region.typeGroupKey;
  }

  /// 초안 소과제들의 단원 매핑으로 그룹 제목을 결정한다.
  /// 개념원리: 소단원 1개 → 소단원명, 같은 중단원 여러 소단원 → 중단원명,
  /// 쎈·RPM: 중단원명 + A/B/C.
  /// 수력충전: 중단원명.
  /// 여러 중단원 → `그룹 과제`.
  String _resolveGroupTitleFromDraftItems(List<_DraftGroupItem> items) {
    if (items.isEmpty) return '그룹 과제';
    if (_hasNaesinDraftItems()) {
      final firstNaesin = items.firstWhere(
        (item) => (item.linkedBookKey ?? '')
            .trim()
            .startsWith(_kNaesinDraftLinkPrefix),
        orElse: () => items.first,
      );
      final naesinTitle = (firstNaesin.naesinGroupTitle ?? '').trim();
      if (naesinTitle.isNotEmpty) return _truncateTitle(naesinTitle, 25);
      return '내신 기출';
    }

    final book = _selectedLinkedBook;
    if (_isSuryeokLinkedBook(book)) {
      final midKeys = <String>{};
      final midNames = <String, String>{};
      for (final item in items) {
        for (final raw in item.unitMappings) {
          final m = Map<String, dynamic>.from(raw);
          final bigOrder = _toInt(m['bigOrder'] ?? m['big_order']);
          final midOrder = _toInt(m['midOrder'] ?? m['mid_order']);
          final midName = '${m['midName'] ?? m['mid_name'] ?? ''}'.trim();
          if (bigOrder == null || midOrder == null) continue;
          final midKey = '$bigOrder|$midOrder';
          midKeys.add(midKey);
          if (midName.isNotEmpty) midNames[midKey] = midName;
        }
      }
      if (midKeys.length == 1) {
        final midName = midNames[midKeys.first] ?? '';
        return midName.isEmpty ? '그룹 과제' : _truncateTitle(midName, 25);
      }
      return '그룹 과제';
    }

    if (_isSsenLikeLinkedBook(book)) {
      final midKeys = <String>{};
      final midNames = <String, String>{};
      final stages = <String>{};
      for (final item in items) {
        for (final raw in item.unitMappings) {
          final m = Map<String, dynamic>.from(raw);
          final bigOrder = _toInt(m['bigOrder'] ?? m['big_order']);
          final midOrder = _toInt(m['midOrder'] ?? m['mid_order']);
          final midName = '${m['midName'] ?? m['mid_name'] ?? ''}'.trim();
          final subKey = '${m['subKey'] ?? m['sub_key'] ?? ''}'.trim();
          final stage = _ssenStageLetter(subKey);
          if (bigOrder == null || midOrder == null) continue;
          final midKey = '$bigOrder|$midOrder';
          midKeys.add(midKey);
          if (midName.isNotEmpty) midNames[midKey] = midName;
          if (stage != null) stages.add(stage);
        }
      }
      if (midKeys.length == 1) {
        final midName = midNames[midKeys.first] ?? '';
        if (midName.isEmpty) return '그룹 과제';
        if (stages.length == 1) {
          return _truncateTitle('$midName ${stages.first}', 25);
        }
        if (stages.length > 1) {
          final ordered = stages.toList()..sort();
          return _truncateTitle('$midName ${ordered.join('/')}', 25);
        }
        return _truncateTitle(midName, 25);
      }
      return '그룹 과제';
    }

    if (_isWonriLinkedBook(book)) {
      final smallKeys = <String>{};
      final midKeys = <String>{};
      final smallNames = <String, String>{};
      final midNames = <String, String>{};
      for (final item in items) {
        for (final raw in item.unitMappings) {
          final m = Map<String, dynamic>.from(raw);
          final bigOrder = _toInt(m['bigOrder'] ?? m['big_order']);
          final midOrder = _toInt(m['midOrder'] ?? m['mid_order']);
          final smallOrder = _toInt(m['smallOrder'] ?? m['small_order']);
          // 개념원리 crop.sub_key 는 A~E(카테고리)라 소단원 키가 될 수 없다.
          // 개념 페이지 초안은 displaySubKey 형식이 달라질 수 있으므로
          // 소단원명(smallName)을 1순위로 동일 소단원을 묶는다.
          final displaySubKey = _normalizedWonriDisplaySubKey(
            '${m['displaySubKey'] ?? m['display_sub_key'] ?? ''}'.trim(),
          );
          final midName = '${m['midName'] ?? m['mid_name'] ?? ''}'.trim();
          final smallName = '${m['smallName'] ?? m['small_name'] ?? ''}'.trim();
          if (bigOrder == null || midOrder == null) continue;
          final midKey = '$bigOrder|$midOrder';
          midKeys.add(midKey);
          if (midName.isNotEmpty) midNames[midKey] = midName;
          final smallKey = smallName.isNotEmpty
              ? '$bigOrder|$midOrder|n:$smallName'
              : (displaySubKey.isNotEmpty
                  ? '$bigOrder|$midOrder|k:$displaySubKey'
                  : (smallOrder != null
                      ? '$bigOrder|$midOrder|o:$smallOrder'
                      : '$bigOrder|$midOrder|t:${item.title.trim()}'));
          smallKeys.add(smallKey);
          final resolvedSmall =
              smallName.isNotEmpty ? smallName : item.title.trim();
          if (resolvedSmall.isNotEmpty) smallNames[smallKey] = resolvedSmall;
        }
      }
      if (smallKeys.isEmpty) {
        // 매핑이 없으면 제목 집합으로 폴백
        final titles =
            items.map((e) => e.title.trim()).where((e) => e.isNotEmpty).toSet();
        if (titles.length == 1) return _truncateTitle(titles.first, 25);
        return '그룹 과제';
      }
      if (smallKeys.length == 1) {
        final name = smallNames[smallKeys.first] ?? items.first.title.trim();
        return name.isEmpty ? '그룹 과제' : _truncateTitle(name, 25);
      }
      if (midKeys.length == 1) {
        final name = midNames[midKeys.first] ?? '';
        return name.isEmpty ? '그룹 과제' : _truncateTitle(name, 25);
      }
      return '그룹 과제';
    }

    final titles = items
        .map((e) => e.title.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (titles.length == 1) return _truncateTitle(titles.first, 25);
    return '그룹 과제';
  }

  void _syncGroupTitleFromDrafts() {
    if (_isChildAddMode) {
      final locked = (widget.lockedGroupTitle ?? '').trim();
      if (locked.isNotEmpty) {
        _setGroupTitleText(locked);
      }
      return;
    }
    if (_groupTitleManuallyEdited) return;
    if (_draftGroupItems.isEmpty) {
      _setGroupTitleText('그룹 과제');
      return;
    }
    _setGroupTitleText(_resolveGroupTitleFromDraftItems(_draftGroupItems));
  }

  bool _isCompletedForIssuedLock(HomeworkItem hw) {
    return hw.status == HomeworkStatus.completed || hw.phase == 4;
  }

  Map<String, Set<int>> _pagesBySmallKeyForIssuedScan(
    List<_BigUnitSelectionNode> units,
  ) {
    final pagesBySmallKey = <String, Set<int>>{};
    for (final big in units) {
      for (final mid in big.middles) {
        for (final small in mid.smalls) {
          final pages = <int>{...small.pageCounts.keys};
          _addPageRange(pages, small.startPage, small.endPage);
          pagesBySmallKey[
                  _smallKey(big.orderIndex, mid.orderIndex, small.orderIndex)] =
              pages;
        }
      }
    }
    return pagesBySmallKey;
  }

  /// 문항이 있는 쪽만. 소단원 회차 배지는 이 쪽을 모두 내줬을 때만 올린다.
  Map<String, Set<int>> _questionPagesBySmallKeyForIssuedScan(
    List<_BigUnitSelectionNode> units,
  ) {
    final pagesBySmallKey = <String, Set<int>>{};
    for (final big in units) {
      for (final mid in big.middles) {
        for (final small in mid.smalls) {
          final pages = <int>{};
          for (final entry in small.pageCounts.entries) {
            if (entry.value > 0) pages.add(entry.key);
          }
          if (pages.isEmpty) {
            _addPageRange(pages, small.startPage, small.endPage);
          }
          pagesBySmallKey[
                  _smallKey(big.orderIndex, mid.orderIndex, small.orderIndex)] =
              pages;
        }
      }
    }
    return pagesBySmallKey;
  }

  Map<String, _IssuedSmallSummary> _issuedSmallSummaryByBook({
    required String bookId,
    required String gradeLabel,
    required List<_BigUnitSelectionNode> units,
  }) {
    if (bookId.trim().isEmpty || gradeLabel.trim().isEmpty) {
      return <String, _IssuedSmallSummary>{};
    }
    final questionPagesBySmallKey =
        _questionPagesBySmallKeyForIssuedScan(units);
    if (questionPagesBySmallKey.isEmpty) {
      return <String, _IssuedSmallSummary>{};
    }

    final latestFinishedAtBySmallKey = <String, DateTime?>{};
    final completedCountBySmallKey = <String, int>{};
    final assignedCountBySmallKey = <String, int>{};
    final items = HomeworkStore.instance.items(widget.studentId);
    for (final hw in items) {
      final hwBookId = (hw.bookId ?? '').trim();
      final hwGrade = (hw.gradeLabel ?? '').trim();
      if (hwBookId != bookId || hwGrade != gradeLabel) continue;

      final finishedAt = hw.completedAt ??
          hw.confirmedAt ??
          hw.submittedAt ??
          hw.updatedAt ??
          hw.createdAt;
      final touched = <String>{};
      final isCompleted = _isCompletedForIssuedLock(hw);

      final pages = _displayPagesFromHomework(hw);
      if (pages.isEmpty) continue;
      for (final entry in questionPagesBySmallKey.entries) {
        if (entry.value.isEmpty) continue;
        if (entry.value.every(pages.contains)) {
          touched.add(entry.key);
        }
      }

      for (final key in touched) {
        assignedCountBySmallKey[key] = (assignedCountBySmallKey[key] ?? 0) + 1;
        if (!isCompleted) continue;
        completedCountBySmallKey[key] =
            (completedCountBySmallKey[key] ?? 0) + 1;
        final prev = latestFinishedAtBySmallKey[key];
        if (prev == null || (finishedAt != null && finishedAt.isAfter(prev))) {
          latestFinishedAtBySmallKey[key] = finishedAt;
        }
      }
    }
    final summary = <String, _IssuedSmallSummary>{};
    final keys = <String>{
      ...assignedCountBySmallKey.keys,
      ...completedCountBySmallKey.keys,
      ...latestFinishedAtBySmallKey.keys,
    };
    for (final key in keys) {
      summary[key] = _IssuedSmallSummary(
        latestFinishedAt: latestFinishedAtBySmallKey[key],
        completedCount: completedCountBySmallKey[key] ?? 0,
        assignedCount: assignedCountBySmallKey[key] ?? 0,
      );
    }
    return summary;
  }

  /// 소단원·쪽별 내준/완료 횟수. 과제 page·unitMappings로 쪽을 판별한다.
  ({
    Map<String, Map<int, int>> assigned,
    Map<String, Map<int, int>> completed,
  }) _issuedPageCountsByBook({
    required String bookId,
    required String gradeLabel,
    required List<_BigUnitSelectionNode> units,
  }) {
    final empty = (
      assigned: <String, Map<int, int>>{},
      completed: <String, Map<int, int>>{},
    );
    if (bookId.trim().isEmpty || gradeLabel.trim().isEmpty) {
      return empty;
    }
    final pagesBySmallKey = _pagesBySmallKeyForIssuedScan(units);
    if (pagesBySmallKey.isEmpty) return empty;

    final assigned = <String, Map<int, int>>{};
    final completed = <String, Map<int, int>>{};
    void bump(Map<String, Map<int, int>> out, String smallKey, int page) {
      final m = out.putIfAbsent(smallKey, () => <int, int>{});
      m[page] = (m[page] ?? 0) + 1;
    }

    final items = HomeworkStore.instance.items(widget.studentId);
    for (final hw in items) {
      final hwBookId = (hw.bookId ?? '').trim();
      final hwGrade = (hw.gradeLabel ?? '').trim();
      if (hwBookId != bookId || hwGrade != gradeLabel) continue;

      final touched = <String>{};
      final mappings = hw.unitMappings;
      if (mappings != null && mappings.isNotEmpty) {
        for (final raw in mappings) {
          final m = Map<String, dynamic>.from(raw);
          final bigOrder = _toInt(m['bigOrder'] ?? m['big_order']);
          final midOrder = _toInt(m['midOrder'] ?? m['mid_order']);
          final smallOrder = _toInt(m['smallOrder'] ?? m['small_order']);
          if (bigOrder == null || midOrder == null || smallOrder == null) {
            continue;
          }
          touched.add(_smallKey(bigOrder, midOrder, smallOrder));
        }
      }

      final pagesHw = _displayPagesFromHomework(hw);
      if (pagesHw.isNotEmpty) {
        for (final entry in pagesBySmallKey.entries) {
          if (_hasPageOverlap(pagesHw, entry.value)) {
            touched.add(entry.key);
          }
        }
      }

      if (pagesHw.isEmpty) continue;
      final isCompleted = _isCompletedForIssuedLock(hw);

      for (final key in touched) {
        final smallPages = pagesBySmallKey[key];
        if (smallPages == null) continue;
        for (final p in pagesHw) {
          if (!smallPages.contains(p)) continue;
          bump(assigned, key, p);
          if (isCompleted) bump(completed, key, p);
        }
      }
    }
    return (assigned: assigned, completed: completed);
  }

  void _applyIssuedLockedState(
    List<_BigUnitSelectionNode> units,
    Map<String, _IssuedSmallSummary> issuedSummaryBySmallKey,
    Set<String> acknowledgedSmallKeys,
    Map<String, Map<int, int>> pageCompletionsBySmallKey,
    Map<String, Map<int, int>> pageAssignedBySmallKey,
  ) {
    for (final big in units) {
      big.explicitSelected = false;
      for (final mid in big.middles) {
        mid.explicitSelected = false;
        for (final small in mid.smalls) {
          final key =
              _smallKey(big.orderIndex, mid.orderIndex, small.orderIndex);
          final summary = issuedSummaryBySmallKey[key];
          final acknowledged = acknowledgedSmallKeys.contains(key);
          // 완료 인정 이력은 표시만 하고 재출제는 허용한다.
          small.locked = false;
          small.finishedAt = summary?.latestFinishedAt;
          small.completedCount =
              (summary?.completedCount ?? 0) + (acknowledged ? 1 : 0);
          small.assignedCount =
              (summary?.assignedCount ?? 0) + (acknowledged ? 1 : 0);
          small.pageCompletedCounts
            ..clear()
            ..addAll(pageCompletionsBySmallKey[key] ?? const {});
          small.pageAssignedCounts
            ..clear()
            ..addAll(pageAssignedBySmallKey[key] ?? const {});
          small.selected = false;
          small.explicitSelected = false;
          small.selectedPages.clear();
        }
        mid.selected = _allSmallSelected(mid);
      }
      big.selected = _allMidSelected(big);
    }
  }

  bool _hasEditableSmallInMid(_MidUnitSelectionNode mid) =>
      mid.smalls.any((s) => !s.locked && !s.draftBlocked);

  bool _hasEditableSmallInBig(_BigUnitSelectionNode big) =>
      big.middles.any(_hasEditableSmallInMid);

  bool _allSmallSelected(_MidUnitSelectionNode mid) {
    final selectable =
        mid.smalls.where((s) => !s.locked && !s.draftBlocked).toList();
    return selectable.isNotEmpty && selectable.every((s) => s.selected);
  }

  bool _allMidSelected(_BigUnitSelectionNode big) =>
      big.middles.isNotEmpty && big.middles.every((m) => _allSmallSelected(m));

  void _toggleBig(_BigUnitSelectionNode big, bool selected) {
    setState(() {
      big.selected = selected;
      big.explicitSelected = selected;
      for (final mid in big.middles) {
        mid.selected = false;
        mid.explicitSelected = false;
        for (final small in mid.smalls) {
          if (small.locked || small.draftBlocked) continue;
          small.selected = selected;
          small.explicitSelected = false;
          small.selectedPages.clear();
        }
        mid.selected = _allSmallSelected(mid);
      }
      big.selected = _allMidSelected(big);
    });
    _refreshRangeAutoDraft();
  }

  void _toggleMid(
      _BigUnitSelectionNode big, _MidUnitSelectionNode mid, bool selected) {
    setState(() {
      big.explicitSelected = false;
      mid.selected = false;
      mid.explicitSelected = selected;
      for (final small in mid.smalls) {
        if (small.locked || small.draftBlocked) continue;
        small.selected = selected;
        small.explicitSelected = false;
        small.selectedPages.clear();
      }
      mid.selected = _allSmallSelected(mid);
      big.selected = _allMidSelected(big);
    });
    _refreshRangeAutoDraft();
  }

  /// 소단원 **체크박스** — 단원 전체 선택(대/중단원과 동일). 페이지 단위 선택은 해제한다.
  void _toggleSmallWhole(
    _BigUnitSelectionNode big,
    _MidUnitSelectionNode mid,
    _SmallUnitSelectionNode small,
    bool selected,
  ) {
    setState(() {
      if (small.locked || small.draftBlocked) return;
      big.explicitSelected = false;
      mid.explicitSelected = false;
      small.selected = selected;
      small.explicitSelected = selected;
      small.selectedPages.clear();
      mid.selected = _allSmallSelected(mid);
      big.selected = _allMidSelected(big);
    });
    _refreshRangeAutoDraft();
  }

  // --- 왼쪽 트리: 펼친 소단원 줄 세로 드래그(전체 단위 일괄 선택). 오른쪽 페이지 Listener와 분리. ---

  Map<String, _SmallDragSnap> _captureAllSmallDragSnapshots() {
    final m = <String, _SmallDragSnap>{};
    for (final big in _units) {
      for (final mid in big.middles) {
        for (final small in mid.smalls) {
          m[_smallExpandKey(big, mid, small)] = _SmallDragSnap.fromNode(small);
        }
      }
    }
    return m;
  }

  List<String> _leftDraggableVisibleSmallExpandKeysOrdered() {
    final out = <String>[];
    for (final big in _units) {
      for (final mid in big.middles) {
        if (_expandedLeftMidSmallsKey != _midExpandKey(big, mid)) continue;
        for (final small in mid.smalls) {
          if (small.locked || small.draftBlocked) continue;
          out.add(_smallExpandKey(big, mid, small));
        }
      }
    }
    return out;
  }

  RenderBox? _leftSmallRowRenderBox(String expandKey) {
    final ctx = _leftSmallRowKeys[expandKey]?.currentContext;
    if (ctx == null) return null;
    final box = ctx.findRenderObject();
    if (box is! RenderBox || !box.attached) return null;
    return box;
  }

  bool _leftSmallRowHitTestGlobal(String expandKey, Offset global) {
    final box = _leftSmallRowRenderBox(expandKey);
    if (box == null) return false;
    final topLeft = box.localToGlobal(Offset.zero);
    return Rect.fromLTWH(
            topLeft.dx, topLeft.dy, box.size.width, box.size.height)
        .contains(global);
  }

  bool _isGlobalOnLeftSmallCheckboxStrip(Offset global, String expandKey) {
    final box = _leftSmallRowRenderBox(expandKey);
    if (box == null) return false;
    final local = box.globalToLocal(global);
    return local.dx >= 0 && local.dx < _kLeftSmallCheckboxHitWidth;
  }

  String? _leftSmallExpandKeyUnderGlobal(Offset global) {
    for (final big in _units) {
      for (final mid in big.middles) {
        if (_expandedLeftMidSmallsKey != _midExpandKey(big, mid)) continue;
        for (final small in mid.smalls) {
          final k = _smallExpandKey(big, mid, small);
          if (_leftSmallRowHitTestGlobal(k, global)) return k;
        }
      }
    }
    return null;
  }

  String? _leftSmallExpandKeyNearestDraggable(Offset global) {
    String? best;
    var bestScore = double.infinity;
    for (final k in _leftDraggableVisibleSmallExpandKeysOrdered()) {
      final box = _leftSmallRowRenderBox(k);
      if (box == null) continue;
      final topLeft = box.localToGlobal(Offset.zero);
      final rect = Rect.fromLTWH(
        topLeft.dx,
        topLeft.dy,
        box.size.width,
        box.size.height,
      );
      final nx = global.dx.clamp(rect.left, rect.right).toDouble();
      final ny = global.dy.clamp(rect.top, rect.bottom).toDouble();
      final horiz = (global.dx - nx).abs();
      final vert = (global.dy - ny).abs();
      final score = vert + horiz * 0.35;
      if (score < bestScore) {
        bestScore = score;
        best = k;
      }
    }
    return best;
  }

  ({
    _BigUnitSelectionNode big,
    _MidUnitSelectionNode mid,
    _SmallUnitSelectionNode small,
  })? _lookupTripleForSmallExpandKey(String expandKey) {
    for (final big in _units) {
      for (final mid in big.middles) {
        for (final small in mid.smalls) {
          if (_smallExpandKey(big, mid, small) == expandKey) {
            return (big: big, mid: mid, small: small);
          }
        }
      }
    }
    return null;
  }

  bool _leftWholeSelectModeForAnchorSmall(_SmallUnitSelectionNode s) {
    if (s.locked || s.draftBlocked) return true;
    if (s.selected && s.selectedPages.isEmpty) return false;
    return true;
  }

  void _applyLeftSmallWholeVisibleRange(
    String anchorExpandKey,
    String curExpandKey,
    bool select,
  ) {
    final baselines = _leftSmallDragBaseline;
    if (baselines == null) return;
    final keys = _leftDraggableVisibleSmallExpandKeysOrdered();
    final ia = keys.indexOf(anchorExpandKey);
    final ib = keys.indexOf(curExpandKey);
    if (ia < 0 || ib < 0) return;
    final lo = ia < ib ? ia : ib;
    final hi = ia < ib ? ib : ia;
    final range = keys.sublist(lo, hi + 1).toSet();

    setState(() {
      for (final big in _units) {
        big.explicitSelected = false;
        for (final mid in big.middles) {
          mid.explicitSelected = false;
          for (final small in mid.smalls) {
            final k = _smallExpandKey(big, mid, small);
            final snap = baselines[k];
            if (snap == null) continue;
            if (!range.contains(k)) {
              small.selected = snap.selected;
              small.explicitSelected = snap.explicitSelected;
              small.selectedPages
                ..clear()
                ..addAll(snap.pages);
            } else {
              if (select) {
                small.selected = true;
                small.explicitSelected = true;
                small.selectedPages.clear();
              } else {
                small.selected = false;
                small.explicitSelected = false;
                small.selectedPages.clear();
              }
            }
          }
          mid.selected = _allSmallSelected(mid);
        }
        big.selected = _allMidSelected(big);
      }
    });
    _refreshRangeAutoDraft();
  }

  void _handleLeftTreePointerDown(PointerDownEvent e) {
    if (_rightPagePointerDown) return;
    final g = e.position;
    final key = _leftSmallExpandKeyUnderGlobal(g);
    if (key == null) return;
    if (_isGlobalOnLeftSmallCheckboxStrip(g, key)) return;
    final triplet = _lookupTripleForSmallExpandKey(key);
    if (triplet == null) return;
    if (triplet.small.locked || triplet.small.draftBlocked) return;

    setState(() {
      _leftSmallDragPointerDown = true;
      _leftSmallDragMovedPastSlop = false;
      _leftSmallDragDownGlobal = g;
      _leftSmallDragAnchorExpandKey = key;
    });
  }

  void _handleLeftTreePointerMove(PointerMoveEvent e) {
    if (!_leftSmallDragPointerDown || _leftSmallDragAnchorExpandKey == null) {
      return;
    }
    final anchor = _leftSmallDragAnchorExpandKey!;
    final g = e.position;

    if (!_leftSmallDragMovedPastSlop) {
      final down = _leftSmallDragDownGlobal;
      if (down == null) return;
      if ((g - down).distance < _kLeftSmallDragSlopPx) return;
      setState(() {
        _leftSmallDragMovedPastSlop = true;
        _leftSmallDragBaseline = _captureAllSmallDragSnapshots();
        final t = _lookupTripleForSmallExpandKey(anchor);
        _leftSmallDragSelectMode =
            t == null ? true : _leftWholeSelectModeForAnchorSmall(t.small);
      });
    }

    final curKey = _leftSmallExpandKeyUnderGlobal(g) ??
        _leftSmallExpandKeyNearestDraggable(g);
    if (curKey == null || _leftSmallDragSelectMode == null) return;
    _applyLeftSmallWholeVisibleRange(
      anchor,
      curKey,
      _leftSmallDragSelectMode!,
    );
  }

  void _handleLeftTreePointerUp(PointerUpEvent e) {
    if (!_leftSmallDragPointerDown) return;
    setState(() {
      _leftSmallDragPointerDown = false;
      _leftSmallDragMovedPastSlop = false;
      _leftSmallDragDownGlobal = null;
      _leftSmallDragAnchorExpandKey = null;
      _leftSmallDragSelectMode = null;
      _leftSmallDragBaseline = null;
    });
  }

  void _handleLeftTreePointerCancel(PointerCancelEvent e) {
    if (!_leftSmallDragPointerDown) return;
    setState(() {
      _leftSmallDragPointerDown = false;
      _leftSmallDragMovedPastSlop = false;
      _leftSmallDragDownGlobal = null;
      _leftSmallDragAnchorExpandKey = null;
      _leftSmallDragSelectMode = null;
      _leftSmallDragBaseline = null;
    });
  }

  /// 잠금·차단이 아닌 페이지 줄만 이어 붙인 순서(중단원 내 드래그 범위).
  List<MapEntry<int, int>> _rightMidUnlockedPageFlat(
      _MidUnitSelectionNode mid) {
    final flat = <MapEntry<int, int>>[];
    for (var si = 0; si < mid.smalls.length; si++) {
      final s = mid.smalls[si];
      if (s.locked || s.draftBlocked) continue;
      final pgs = _smallPages(s).toList()..sort();
      if (pgs.isEmpty) continue;
      for (var pi = 0; pi < pgs.length; pi++) {
        flat.add(MapEntry(si, pi));
      }
    }
    return flat;
  }

  void _applyCrossSmallMidPageRange(
    _BigUnitSelectionNode big,
    _MidUnitSelectionNode mid,
    int anchorSi,
    int anchorPi,
    int curSi,
    int curPi,
    bool select,
  ) {
    final baselines = _pageListDragBaselineBySmallIndex;
    if (baselines == null || baselines.length != mid.smalls.length) return;

    final flat = _rightMidUnlockedPageFlat(mid);
    int findFlat(int si, int pi) {
      for (var i = 0; i < flat.length; i++) {
        if (flat[i].key == si && flat[i].value == pi) return i;
      }
      return -1;
    }

    final a = findFlat(anchorSi, anchorPi);
    final b = findFlat(curSi, curPi);
    if (a < 0 || b < 0) return;
    final lo = a < b ? a : b;
    final hi = a < b ? b : a;

    final spanBySmall = <int, Set<int>>{};
    for (var i = lo; i <= hi; i++) {
      final si = flat[i].key;
      final pi = flat[i].value;
      final pgs = _smallPages(mid.smalls[si]).toList()..sort();
      spanBySmall.putIfAbsent(si, () => <int>{}).add(pgs[pi]);
    }

    setState(() {
      big.explicitSelected = false;
      mid.explicitSelected = false;
      for (var si = 0; si < mid.smalls.length; si++) {
        final s = mid.smalls[si];
        if (s.locked || s.draftBlocked) continue;
        final span = spanBySmall[si] ?? <int>{};
        final next = Set<int>.from(baselines[si]);
        if (select) {
          next.addAll(span);
        } else {
          next.removeAll(span);
        }
        s.selected = false;
        s.explicitSelected = false;
        s.selectedPages
          ..clear()
          ..addAll(next);
      }
      mid.selected = _allSmallSelected(mid);
      big.selected = _allMidSelected(big);
    });
    _refreshRangeAutoDraft();
  }

  Widget _buildRightPageRowMeta({
    required _SmallUnitSelectionNode small,
    required int pageNum,
    required bool blocked,
  }) {
    final q = small.pageCounts[pageNum] ?? 0;
    final done = small.pageCompletedCounts[pageNum] ?? 0;
    final assigned = small.pageAssignedCounts[pageNum] ?? 0;
    if (q <= 0 && assigned <= 0) {
      return Text(
        '개념',
        style: TextStyle(
          color: blocked ? const Color(0xFF6D7777) : kDlgTextSub,
          fontWeight: FontWeight.w600,
          fontSize: 12.5,
        ),
      );
    }
    final subStyle = TextStyle(
      color: blocked ? const Color(0xFF6D7777) : kDlgTextSub,
      fontWeight: FontWeight.w600,
      fontSize: 12.5,
    );
    final doneStyle = TextStyle(
      color: blocked ? kDlgAccent.withOpacity(0.55) : kDlgAccent,
      fontWeight: FontWeight.w800,
      fontSize: 13,
      height: 1.2,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (q > 0) Text('$q문항', style: subStyle),
        if (q > 0 && assigned > 0) const SizedBox(width: 8),
        if (assigned > 0) Text('$done/$assigned', style: doneStyle),
      ],
    );
  }

  /// 오른쪽 페이지 줄 체크 표시·드래그 기준용. 단원 전체 선택(`selected`)이면 모든 페이지가 선택된 것으로 본다.
  bool _isRightPageChecked(_SmallUnitSelectionNode small, int pageNum) {
    if (small.locked || small.draftBlocked) return false;
    if (small.selected) return true;
    return small.selectedPages.contains(pageNum);
  }

  List<_RightFlatEntry> _rightFlatEntries(_MidUnitSelectionNode mid) {
    final out = <_RightFlatEntry>[];
    for (var si = 0; si < mid.smalls.length; si++) {
      out.add(_RightFlatEntry(smallIndex: si, isHeader: true));
      final pages = _smallPages(mid.smalls[si]).toList()..sort();
      for (var pi = 0; pi < pages.length; pi++) {
        out.add(_RightFlatEntry(
          smallIndex: si,
          isHeader: false,
          pageSortedIndex: pi,
        ));
      }
    }
    return out;
  }

  double _rightFlatEntryHeight(_RightFlatEntry e) {
    return e.isHeader ? _kMidRightSmallHeaderHeight : _kSmallPageListRowStride;
  }

  double _rightFlatContentHeight(_MidUnitSelectionNode mid) {
    var h = 0.0;
    for (final e in _rightFlatEntries(mid)) {
      h += _rightFlatEntryHeight(e);
    }
    return h;
  }

  _RightListHit? _rightFlatHitAtLocalY(
      _MidUnitSelectionNode mid, double localY) {
    if (localY < 0) return null;
    var y = 0.0;
    for (final e in _rightFlatEntries(mid)) {
      final eh = _rightFlatEntryHeight(e);
      if (localY >= y && localY < y + eh) {
        return _RightListHit(
          smallIndex: e.smallIndex,
          isHeader: e.isHeader,
          pageSortedIndex: e.pageSortedIndex,
        );
      }
      y += eh;
    }
    return null;
  }

  /// 헤더 위로 지나갈 때 등: 가장 가까운(잠금 아닌) 페이지 줄로 스냅.
  _RightListHit? _rightFlatNearestUnblockedPageHit(
    _MidUnitSelectionNode mid,
    double localY,
  ) {
    var bestDist = double.infinity;
    _RightListHit? best;
    var y = 0.0;
    for (final e in _rightFlatEntries(mid)) {
      final eh = _rightFlatEntryHeight(e);
      if (!e.isHeader && e.pageSortedIndex != null) {
        final s = mid.smalls[e.smallIndex];
        if (!s.locked && !s.draftBlocked) {
          final centerY = y + eh / 2;
          final d = (localY - centerY).abs();
          if (d < bestDist) {
            bestDist = d;
            best = _RightListHit(
              smallIndex: e.smallIndex,
              isHeader: false,
              pageSortedIndex: e.pageSortedIndex,
            );
          }
        }
      }
      y += eh;
    }
    return best;
  }

  _RightListHit? _rightFlatPageHitForDrag(
    _MidUnitSelectionNode mid,
    double localY,
  ) {
    final hit = _rightFlatHitAtLocalY(mid, localY);
    if (hit != null && !hit.isHeader && hit.pageSortedIndex != null) {
      final s = mid.smalls[hit.smallIndex];
      if (!s.locked && !s.draftBlocked) {
        return hit;
      }
    }
    return _rightFlatNearestUnblockedPageHit(mid, localY);
  }

  void _handleRightPageScrollSignal(PointerSignalEvent s) {
    if (s is! PointerScrollEvent) return;
    final c = _rangeRightScrollController;
    if (!c.hasClients) return;
    final next = (c.offset + s.scrollDelta.dy)
        .clamp(0.0, c.position.maxScrollExtent)
        .toDouble();
    c.jumpTo(next);
  }

  void _beginSmallPageDragAt(
    _BigUnitSelectionNode big,
    _MidUnitSelectionNode mid,
    _SmallUnitSelectionNode small,
    List<int> pages,
    int idx,
  ) {
    if (small.locked || small.draftBlocked || pages.isEmpty) return;
    final safeIdx = idx.clamp(0, pages.length - 1);
    final page = pages[safeIdx];
    final selectMode = !_isRightPageChecked(small, page);
    setState(() {
      _pageListDragAnchorIndex = safeIdx;
      _pageListDragSelectMode = selectMode;
    });
    _applyCrossSmallMidPageRange(
      big,
      mid,
      _rightPagePageSmallIdx!,
      safeIdx,
      _rightPagePageSmallIdx!,
      safeIdx,
      selectMode,
    );
  }

  void _applyWholeSmallRangeIndices(
    _BigUnitSelectionNode big,
    _MidUnitSelectionNode mid,
    int loIdx,
    int hiIdx,
    bool select,
  ) {
    if (mid.smalls.isEmpty) return;
    var lo = loIdx.clamp(0, mid.smalls.length - 1);
    var hi = hiIdx.clamp(0, mid.smalls.length - 1);
    if (lo > hi) {
      final t = lo;
      lo = hi;
      hi = t;
    }
    setState(() {
      big.explicitSelected = false;
      mid.explicitSelected = false;
      for (var i = lo; i <= hi; i++) {
        final s = mid.smalls[i];
        if (s.locked || s.draftBlocked) continue;
        s.selected = select;
        s.explicitSelected = select;
        s.selectedPages.clear();
      }
      mid.selected = _allSmallSelected(mid);
      big.selected = _allMidSelected(big);
    });
    _refreshRangeAutoDraft();
  }

  void _handleRightPagePointerDown(
    PointerDownEvent e,
    _BigUnitSelectionNode big,
    _MidUnitSelectionNode mid,
  ) {
    final hit = _rightFlatHitAtLocalY(mid, e.localPosition.dy);
    if (hit == null) return;
    final small = mid.smalls[hit.smallIndex];
    if (small.locked || small.draftBlocked) return;

    setState(() {
      _rightPagePointerDown = true;
      _rightPagePointerDownLocal = e.localPosition;
      _rightPageDragMoved = false;
    });

    if (!hit.isHeader && hit.pageSortedIndex != null) {
      final pages = _smallPages(small).toList()..sort();
      if (pages.isEmpty) return;
      setState(() {
        _rightPageSessionKind = 'page';
        _rightPagePageSmallIdx = hit.smallIndex;
        _pageListDragBaselineBySmallIndex = List<Set<int>>.generate(
          mid.smalls.length,
          (si) {
            final s = mid.smalls[si];
            final pgs = _smallPages(s).toList()..sort();
            if (s.locked || s.draftBlocked) {
              return Set<int>.from(s.selectedPages);
            }
            return s.selected ? pgs.toSet() : Set<int>.from(s.selectedPages);
          },
        );
      });
      _beginSmallPageDragAt(
        big,
        mid,
        small,
        pages,
        hit.pageSortedIndex!,
      );
    } else if (hit.isHeader) {
      setState(() {
        _rightPageSessionKind = 'whole';
        _rightPageWholeAnchorSmallIdx = hit.smallIndex;
        _rightPageWholeSelectMode = !small.selected;
      });
    }
  }

  void _handleRightPagePointerMove(
    PointerMoveEvent e,
    _BigUnitSelectionNode big,
    _MidUnitSelectionNode mid,
  ) {
    if (!_rightPagePointerDown || _rightPagePointerDownLocal == null) {
      return;
    }
    final down = _rightPagePointerDownLocal!;

    if (_rightPageSessionKind == 'page' && _rightPagePageSmallIdx != null) {
      final anchor = _pageListDragAnchorIndex;
      final mode = _pageListDragSelectMode;
      if (anchor == null || mode == null) return;
      final hit = _rightFlatPageHitForDrag(mid, e.localPosition.dy);
      if (hit == null || hit.pageSortedIndex == null) return;
      _applyCrossSmallMidPageRange(
        big,
        mid,
        _rightPagePageSmallIdx!,
        anchor,
        hit.smallIndex,
        hit.pageSortedIndex!,
        mode,
      );
      return;
    }

    if (_rightPageSessionKind == 'whole' &&
        _rightPageWholeAnchorSmallIdx != null &&
        _rightPageWholeSelectMode != null) {
      if ((e.localPosition - down).distance <= 4) return;
      if (!_rightPageDragMoved) {
        setState(() => _rightPageDragMoved = true);
      }
      final hit = _rightFlatHitAtLocalY(mid, e.localPosition.dy);
      final curIdx = hit?.smallIndex ?? _rightPageWholeAnchorSmallIdx!;
      final anchor = _rightPageWholeAnchorSmallIdx!;
      final lo = curIdx < anchor ? curIdx : anchor;
      final hi = curIdx > anchor ? curIdx : anchor;
      _applyWholeSmallRangeIndices(
        big,
        mid,
        lo,
        hi,
        _rightPageWholeSelectMode!,
      );
    }
  }

  void _handleRightPagePointerUp(
    PointerUpEvent e,
    _BigUnitSelectionNode big,
    _MidUnitSelectionNode mid,
  ) {
    if (!_rightPagePointerDown) return;

    setState(() {
      _pageListDragAnchorIndex = null;
      _pageListDragSelectMode = null;
      _pageListDragBaselineBySmallIndex = null;
      _rightPagePointerDown = false;
      _rightPagePointerDownLocal = null;
      _rightPageDragMoved = false;
      _rightPageSessionKind = '';
      _rightPageWholeAnchorSmallIdx = null;
      _rightPageWholeSelectMode = null;
      _rightPagePageSmallIdx = null;
    });
  }

  void _handleRightPagePointerCancel() {
    setState(() {
      _pageListDragAnchorIndex = null;
      _pageListDragSelectMode = null;
      _pageListDragBaselineBySmallIndex = null;
      _rightPagePointerDown = false;
      _rightPagePointerDownLocal = null;
      _rightPageDragMoved = false;
      _rightPageSessionKind = '';
      _rightPageWholeAnchorSmallIdx = null;
      _rightPageWholeSelectMode = null;
      _rightPagePageSmallIdx = null;
    });
  }

  List<_SelectedSmallUnit> _selectedSmallUnits() {
    final out = <_SelectedSmallUnit>[];
    for (final big in _units) {
      for (final mid in big.middles) {
        for (final small in mid.smalls) {
          if (small.locked || small.draftBlocked) continue;
          if (small.selected) {
            out.add(
              _SelectedSmallUnit(
                bigName: big.name,
                midName: mid.name,
                smallName: small.name,
                bigOrder: big.orderIndex,
                midOrder: mid.orderIndex,
                smallOrder: small.orderIndex,
                startPage: small.startPage,
                endPage: small.endPage,
                pageCounts: small.pageCounts,
              ),
            );
            continue;
          }
          if (small.selectedPages.isEmpty) continue;
          final pages = small.selectedPages
              .where((p) => _smallPages(small).contains(p))
              .toList()
            ..sort();
          out.addAll(
            _coalesceConsecutivePagesForSmall(
              big.name,
              mid.name,
              small.name,
              big.orderIndex,
              mid.orderIndex,
              small.orderIndex,
              pages,
              small.pageCounts,
            ),
          );
        }
      }
    }
    return out;
  }

  List<_SelectedSmallUnit> _coalesceConsecutivePagesForSmall(
    String bigName,
    String midName,
    String smallName,
    int bigOrder,
    int midOrder,
    int smallOrder,
    List<int> sortedPages,
    Map<int, int> pageCounts,
  ) {
    if (sortedPages.isEmpty) return const [];
    final runs = <List<int>>[];
    var run = <int>[sortedPages.first];
    for (var i = 1; i < sortedPages.length; i++) {
      final p = sortedPages[i];
      if (p == run.last + 1) {
        run.add(p);
      } else {
        runs.add(run);
        run = <int>[p];
      }
    }
    runs.add(run);
    return runs.map((run) {
      final lo = run.first;
      final hi = run.last;
      final counts = <int, int>{};
      for (final p in run) {
        if (pageCounts.containsKey(p)) counts[p] = pageCounts[p]!;
      }
      return _SelectedSmallUnit(
        bigName: bigName,
        midName: midName,
        smallName: smallName,
        bigOrder: bigOrder,
        midOrder: midOrder,
        smallOrder: smallOrder,
        startPage: lo,
        endPage: hi,
        pageCounts: counts,
      );
    }).toList();
  }

  /// 같은 소단원 안에서 인접·겹치는 페이지 구간을 합쳐 `1-5` 형태로 표기한다.
  String _mergedPageText(List<_SelectedSmallUnit> selected) {
    final sorted = _sortedSelectedSmallUnits(selected);
    if (sorted.isEmpty) return '';
    final ranges = <String>[];
    String? gKey;
    int? mergeLo;
    int? mergeHi;

    void flushGroup() {
      if (gKey == null || mergeLo == null || mergeHi == null) return;
      ranges.add(mergeLo == mergeHi ? '$mergeLo' : '$mergeLo-$mergeHi');
    }

    for (final s in sorted) {
      if (s.startPage == null || s.endPage == null) continue;
      final key = '${s.bigOrder}|${s.midOrder}|${s.smallOrder}';
      final lo = s.startPage!;
      final hi = s.endPage!;
      if (key != gKey) {
        flushGroup();
        gKey = key;
        mergeLo = lo;
        mergeHi = hi;
      } else {
        final curHi = mergeHi!;
        if (lo <= curHi + 1) {
          if (hi > curHi) {
            mergeHi = hi;
          }
        } else {
          flushGroup();
          mergeLo = lo;
          mergeHi = hi;
        }
      }
    }
    flushGroup();
    return ranges.join(', ');
  }

  String? _mergedCountText(List<_SelectedSmallUnit> selected) {
    int total = 0;
    bool hasAny = false;
    for (final s in selected) {
      if (s.pageCounts.isEmpty) continue;
      hasAny = true;
      for (final v in s.pageCounts.values) {
        total += v;
      }
    }
    if (!hasAny) return null;
    return total.toString();
  }

  List<_SelectedSmallUnit> _sortedSelectedSmallUnits(
      List<_SelectedSmallUnit> selected) {
    final list = List<_SelectedSmallUnit>.from(selected);
    list.sort((a, b) {
      if (a.bigOrder != b.bigOrder) return a.bigOrder.compareTo(b.bigOrder);
      if (a.midOrder != b.midOrder) return a.midOrder.compareTo(b.midOrder);
      if (a.smallOrder != b.smallOrder)
        return a.smallOrder.compareTo(b.smallOrder);
      final ap = a.startPage ?? 0;
      final bp = b.startPage ?? 0;
      if (ap != bp) return ap.compareTo(bp);
      final byBig = a.bigName.compareTo(b.bigName);
      if (byBig != 0) return byBig;
      final byMid = a.midName.compareTo(b.midName);
      if (byMid != 0) return byMid;
      return a.smallName.compareTo(b.smallName);
    });
    return list;
  }

  String _n(int v) => v >= (1 << 29) ? '-' : '${v + 1}';

  String _pageTextForSmall(_SmallUnitSelectionNode small) {
    if (small.startPage == null || small.endPage == null) return '';
    if (small.startPage == small.endPage) return '${small.startPage}';
    return '${small.startPage}-${small.endPage}';
  }

  String _countTextForSmall(_SmallUnitSelectionNode small) {
    if (small.pageCounts.isEmpty) return '';
    int sum = 0;
    for (final v in small.pageCounts.values) {
      sum += v;
    }
    return sum.toString();
  }

  String _smallRowStatusSuffix(_SmallUnitSelectionNode small) {
    if (small.draftBlocked) return '추가됨';
    if (small.assignedCount > 0 || small.completedCount > 0) {
      return '${small.completedCount}/${math.max(small.assignedCount, small.completedCount)}';
    }
    if (small.selectedPages.isNotEmpty) {
      var sum = 0;
      for (final p in small.selectedPages) {
        sum += small.pageCounts[p] ?? 0;
      }
      if (sum > 0) return '${sum}문항';
      return '${small.selectedPages.length}쪽';
    }
    final count = _countTextForSmall(small);
    return count.isEmpty ? '-문항' : '${count}문항';
  }

  String _bookMetaText(_LinkedTextbook book) {
    final lines = <String>['교재: ${book.bookName}'];
    final grade = book.gradeLabel.trim();
    if (grade.isNotEmpty) {
      lines.add('과정: $grade');
    }
    return lines.join('\n');
  }

  void _setControllerText(TextEditingController controller, String text) {
    if (controller.text == text) return;
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  String _prefixFromSelectedSmall(_SelectedSmallUnit small) =>
      '${_n(small.bigOrder)}.${_n(small.midOrder)}.(${_n(small.smallOrder)})';

  String _prefixFromBigOrder(int bigOrder) => _n(bigOrder);

  String _prefixFromMidOrder(int bigOrder, int midOrder) =>
      '${_n(bigOrder)}.${_n(midOrder)}';

  _ExplicitSelectionAutoTitle? _resolveExplicitSelectionAutoTitle() {
    final explicitBigs = <_BigUnitSelectionNode>[];
    final explicitMids =
        <MapEntry<_BigUnitSelectionNode, _MidUnitSelectionNode>>[];

    for (final big in _units) {
      if (big.explicitSelected && big.selected) {
        explicitBigs.add(big);
      }
      for (final mid in big.middles) {
        if (mid.explicitSelected && mid.selected) {
          explicitMids.add(MapEntry(big, mid));
        }
      }
    }

    if (explicitBigs.length == 1 && explicitMids.isEmpty) {
      final big = explicitBigs.first;
      final prefix = _prefixFromBigOrder(big.orderIndex);
      return _ExplicitSelectionAutoTitle(
        title: '$prefix ${big.name}',
        sourceUnitLevel: 'big',
        sourceUnitPath: prefix,
        pathSummary: big.name,
      );
    }

    if (explicitMids.length == 1 && explicitBigs.isEmpty) {
      final ref = explicitMids.first;
      final big = ref.key;
      final mid = ref.value;
      final prefix = _prefixFromMidOrder(big.orderIndex, mid.orderIndex);
      return _ExplicitSelectionAutoTitle(
        title: '$prefix ${mid.name}',
        sourceUnitLevel: 'mid',
        sourceUnitPath: prefix,
        pathSummary: '${big.name} > ${mid.name}',
      );
    }

    return null;
  }

  String _rangeScopeTextFromSelected(List<_SelectedSmallUnit> selected) {
    if (selected.isEmpty) return '-';
    final sorted = _sortedSelectedSmallUnits(selected);
    final firstPrefix = _prefixFromSelectedSmall(sorted.first);
    if (sorted.length == 1) return firstPrefix;
    final lastPrefix = _prefixFromSelectedSmall(sorted.last);
    return '$firstPrefix ~ $lastPrefix (${sorted.length}개)';
  }

  String _aiSummarySourceForSelection(
    _LinkedTextbook book,
    List<_SelectedSmallUnit> selected,
  ) {
    final sorted = _sortedSelectedSmallUnits(selected);
    final b = StringBuffer();
    b.writeln('교재: ${book.bookName}');
    final grade = book.gradeLabel.trim();
    if (grade.isNotEmpty) b.writeln('과정: $grade');
    b.writeln('범위 요약 대상 소단원 수: ${sorted.length}');
    for (final s in sorted.take(14)) {
      final pageText = (s.startPage == null || s.endPage == null)
          ? ''
          : (s.startPage == s.endPage
              ? 'p.${s.startPage}'
              : 'p.${s.startPage}-${s.endPage}');
      final item = '${s.bigName} > ${s.midName} > ${s.smallName}';
      b.writeln(pageText.isEmpty ? item : '$item ($pageText)');
    }
    if (sorted.length > 14) {
      b.writeln('외 ${sorted.length - 14}개');
    }
    return b.toString();
  }

  Future<String> _createAiSummaryLabel(
    _LinkedTextbook book,
    List<_SelectedSmallUnit> selected,
  ) async {
    try {
      final summary = await AiSummaryService.summarize(
        _aiSummarySourceForSelection(book, selected),
        maxChars: 52,
      );
      return summary.trim();
    } catch (_) {
      return '';
    }
  }

  Future<void> _applyAiSummaryForMultiSelection({
    required int requestId,
    required _LinkedTextbook book,
    required List<_SelectedSmallUnit> selected,
  }) async {
    final summary = await _createAiSummaryLabel(book, selected);
    if (!mounted || requestId != _rangeAiRequestId) return;
    final normalized = summary.trim();
    if (normalized.isNotEmpty) {
      final rangeText = _rangeScopeTextFromSelected(selected);
      _setControllerText(_rangeTitle, normalized);
      _setControllerText(
        _rangeContent,
        '${_bookMetaText(book)}\n범위: $rangeText\n요약: $normalized',
      );
    }
    if (mounted && requestId == _rangeAiRequestId) {
      setState(() => _rangeAiLoading = false);
    }
  }

  List<Map<String, dynamic>> _unitMappingsFromSelectedSmalls(
    List<_SelectedSmallUnit> selected,
  ) {
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final s in selected) {
      final key =
          '${s.bigOrder}|${s.midOrder}|${s.smallOrder}|${s.startPage ?? 'n'}|${s.endPage ?? 'n'}';
      if (!seen.add(key)) continue;
      int? pageCount;
      if (s.pageCounts.isNotEmpty) {
        int sum = 0;
        for (final v in s.pageCounts.values) {
          sum += v;
        }
        pageCount = sum;
      }
      out.add({
        'bigOrder': s.bigOrder,
        'midOrder': s.midOrder,
        'smallOrder': s.smallOrder,
        'bigName': s.bigName,
        'midName': s.midName,
        'smallName': s.smallName,
        'startPage': s.startPage,
        'endPage': s.endPage,
        'pageCoordinate': 'display',
        'pageCount': pageCount,
        'pageCounts': s.pageCounts.isNotEmpty
            ? Map<String, int>.fromEntries(
                s.pageCounts.entries
                    .map((e) => MapEntry(e.key.toString(), e.value)),
              )
            : null,
        'weight': 1.0,
        'sourceScope': 'direct_small',
      });
    }
    return out;
  }

  _UnitTask? _buildMergedRangeTask(_LinkedTextbook book) {
    if (_rangePickerMode == 'type') {
      return _buildProblemSelectionTask(book);
    }
    final selected = _sortedSelectedSmallUnits(_selectedSmallUnits());
    if (selected.isEmpty) return null;
    final first = selected.first;
    final firstPrefix = _prefixFromSelectedSmall(first);
    final explicitAutoTitle = _resolveExplicitSelectionAutoTitle();
    final page = _mergedPageText(selected);
    final count = _mergedCountText(selected) ?? '';
    final singleSmallTitle =
        first.smallName.trim().isEmpty ? '교재 과제' : first.smallName.trim();
    final title = explicitAutoTitle?.title ??
        (selected.length == 1
            ? singleSmallTitle
            : '교재 과제 (${selected.length}개 소단원)');
    final pathSummary = explicitAutoTitle?.pathSummary ??
        (selected.length == 1
            ? '${first.bigName} > ${first.midName} > ${first.smallName}'
            : '${first.bigName} > ${first.midName} > ${first.smallName} 외 ${selected.length - 1}개');
    final sourceUnitLevel = explicitAutoTitle?.sourceUnitLevel ?? 'merged';
    final sourceUnitPath = explicitAutoTitle?.sourceUnitPath ??
        (selected.length == 1
            ? firstPrefix
            : '$firstPrefix 외 ${selected.length - 1}개');
    final allowAiSummaryTitle =
        explicitAutoTitle == null && selected.length > 1;
    return _UnitTask(
      title: title,
      page: page,
      count: count,
      content: '${_bookMetaText(book)}\n$pathSummary',
      sourceUnitLevel: sourceUnitLevel,
      sourceUnitPath: sourceUnitPath,
      unitMappings: _unitMappingsFromSelectedSmalls(selected),
      allowAiSummaryTitle: allowAiSummaryTitle,
    );
  }

  _UnitTask? _buildProblemSelectionTask(_LinkedTextbook book) {
    final selected = _selectedProblemRegions();
    if (selected.isEmpty) return null;
    final pages = selected.map((region) => region.displayPage).toSet();
    final pageText = _pagesToCompactText(pages);
    final byPage = <int, int>{};
    for (final region in selected) {
      byPage[region.displayPage] = (byPage[region.displayPage] ?? 0) + 1;
    }
    final groupLabels = <String>[];
    for (final region in selected) {
      final label = region.typeGroupLabel.trim();
      if (label.isNotEmpty && !groupLabels.contains(label)) {
        groupLabels.add(label);
      }
    }
    final title = groupLabels.length == 1
        ? groupLabels.first
        : '유형별 문항 ${selected.length}개';
    final content = [
      _bookMetaText(book),
      '유형: ${groupLabels.isEmpty ? '유형 미분류' : groupLabels.take(3).join(', ')}',
      '문항: ${selected.map((e) => e.problemNumber).join(', ')}',
    ].join('\n');
    final mappings = <Map<String, dynamic>>[
      {
        'selectionMode': 'problem',
        'sourceScope': 'problem_regions',
        'pageCounts': Map<String, int>.fromEntries(
          byPage.entries.map((entry) => MapEntry('${entry.key}', entry.value)),
        ),
        'startPage': pages.isEmpty ? null : pages.reduce(math.min),
        'endPage': pages.isEmpty ? null : pages.reduce(math.max),
        'pageCoordinate': 'display',
        'pageCount': selected.length,
        'problemCount': selected.length,
        'problemNumbers': selected.map((e) => e.problemNumber).toList(),
        'problemCrops': selected.map((e) => e.toMappingJson()).toList(),
        'problemStage': _migratedProblemStageCode,
        'typeGroups': groupLabels,
      }
    ];
    return _UnitTask(
      title: title,
      page: pageText,
      count: '${selected.length}',
      content: content,
      sourceUnitLevel: 'problem',
      sourceUnitPath: groupLabels.isEmpty ? '유형 미분류' : groupLabels.join(', '),
      unitMappings: mappings,
      allowAiSummaryTitle: false,
    );
  }

  /// 소단원(`bigOrder|midOrder|subKey`) → 소단원 노드 조회용 맵.
  Map<String, _SmallUnitSelectionNode> _smallNodeByUnitKey() {
    final out = <String, _SmallUnitSelectionNode>{};
    for (final big in _units) {
      for (final mid in big.middles) {
        for (final small in mid.smalls) {
          out['${big.orderIndex}|${mid.orderIndex}|${small.subKey}'] = small;
        }
      }
    }
    return out;
  }

  /// 현재 선택을 소단원 단위로 분해해 자동 하위과제 목록을 만든다.
  /// 문항 정보가 있으면 문항 기반, 없으면 페이지 기반으로 동작한다.
  List<_DraftGroupItem> _buildAutoSubtaskDraftItems(_LinkedTextbook book) {
    if (_rangePickerMode == 'type') {
      return _buildProblemSubtaskDraftItems(book);
    }
    return _buildPageSubtaskDraftItems(book);
  }

  /// 페이지 기반(fallback): 선택 소단원을 소단원별 하위과제로 만든다.
  List<_DraftGroupItem> _buildPageSubtaskDraftItems(_LinkedTextbook book) {
    final selected = _sortedSelectedSmallUnits(_selectedSmallUnits());
    if (selected.isEmpty) return const <_DraftGroupItem>[];
    final groups = <String, List<_SelectedSmallUnit>>{};
    final order = <String>[];
    for (final s in selected) {
      final key = '${s.bigOrder}|${s.midOrder}|${s.smallOrder}';
      if (!groups.containsKey(key)) order.add(key);
      groups.putIfAbsent(key, () => <_SelectedSmallUnit>[]).add(s);
    }
    final items = <_DraftGroupItem>[];
    for (final key in order) {
      final group = groups[key]!;
      final first = group.first;
      final title =
          first.smallName.trim().isEmpty ? '교재 과제' : first.smallName.trim();
      final pathSummary =
          '${first.bigName} > ${first.midName} > ${first.smallName}';
      items.add(
        _assembleSubtaskDraftItem(
          book: book,
          title: title,
          page: _mergedPageText(group),
          count: _mergedCountText(group) ?? '',
          pathSummary: pathSummary,
          sourceUnitLevel: 'merged',
          sourceUnitPath: _prefixFromSelectedSmall(first),
          unitMappings: _unitMappingsFromSelectedSmalls(group),
          draftKey: 'auto_page_$key',
        ),
      );
    }
    return items;
  }

  /// 탐색기 소단원 key(`big|mid|U*`)에서 실제 소단원 subKey(U*)만 추출.
  String _explorerSmallSubKey(String smallKey) {
    final trimmed = smallKey.trim();
    if (trimmed.isEmpty) return '';
    final parts = trimmed.split('|');
    return parts.isEmpty ? trimmed : parts.last.trim();
  }

  /// 개념원리 그룹제목용 displaySubKey 정규화.
  /// `0|1|U2`처럼 이미 경로가 붙은 값은 마지막 토큰만 쓴다.
  String _normalizedWonriDisplaySubKey(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    if (!trimmed.contains('|')) return trimmed;
    return _explorerSmallSubKey(trimmed);
  }

  /// 마이그레이션 개념/문항 초안을 같은 소단원으로 묶는 키.
  String? _migratedConceptUnitKey({
    required int bigOrder,
    required int midOrder,
    required String smallName,
    int? smallOrder,
  }) {
    final name = smallName.trim();
    if (name.isNotEmpty) return '$bigOrder|$midOrder|n:$name';
    if (smallOrder != null) return '$bigOrder|$midOrder|o:$smallOrder';
    return null;
  }

  /// 문항 기반: 선택 문항을 유형 그룹(소단원·유형)별 하위과제로 만든다.
  List<_DraftGroupItem> _buildProblemSubtaskDraftItems(_LinkedTextbook book) {
    final selected = _selectedProblemRegions();
    final selectedConceptPages = _selectedMigratedConceptPages();
    if (selected.isEmpty && selectedConceptPages.isEmpty) {
      return const <_DraftGroupItem>[];
    }
    final smallNodes = _smallNodeByUnitKey();
    final conceptPagesByUnit = <String, List<_SelectedMigratedConceptPage>>{};
    final orphanConceptPages = <_SelectedMigratedConceptPage>[];
    for (final page in selectedConceptPages) {
      final key = _migratedConceptUnitKey(
        bigOrder: page.bigOrder,
        midOrder: page.midOrder,
        smallName: page.smallName,
        smallOrder: page.smallOrder,
      );
      if (key == null) {
        orphanConceptPages.add(page);
        continue;
      }
      conceptPagesByUnit
          .putIfAbsent(key, () => <_SelectedMigratedConceptPage>[])
          .add(page);
    }
    final groups = <String, List<_TextbookProblemRegion>>{};
    final order = <String>[];
    for (final region in selected) {
      final key = _problemSubtaskGroupKey(region, book);
      if (!groups.containsKey(key)) order.add(key);
      groups.putIfAbsent(key, () => <_TextbookProblemRegion>[]).add(region);
    }
    final items = <_DraftGroupItem>[];
    for (final key in order) {
      final regions = groups[key]!;
      final smallNode = _resolveSmallNodeForRegions(regions, smallNodes);
      final first = regions.first;
      final conceptUnitKey = _migratedConceptUnitKey(
        bigOrder: first.bigOrder,
        midOrder: first.midOrder,
        smallName: (smallNode?.name ?? first.smallName),
        smallOrder: smallNode?.orderIndex,
      );
      final conceptPages = conceptUnitKey == null
          ? const <_SelectedMigratedConceptPage>[]
          : (conceptPagesByUnit.remove(conceptUnitKey) ??
              const <_SelectedMigratedConceptPage>[]);
      items.add(
        _buildProblemSubtaskDraftItem(
          book,
          regions,
          smallNode,
          draftKey: 'auto_prob_$key',
          extraConceptPages:
              conceptPages.map((page) => page.displayPage).toSet(),
        ),
      );
    }
    if (orphanConceptPages.isNotEmpty) {
      items.add(
        _buildMigratedConceptPageDraftItem(
          book,
          orphanConceptPages,
          draftKey: 'auto_concept_orphan',
        ),
      );
    }
    for (final entry in conceptPagesByUnit.entries) {
      final pages = entry.value;
      if (pages.isEmpty) continue;
      items.add(
        _buildMigratedConceptPageDraftItem(
          book,
          pages,
          draftKey: 'auto_concept_${entry.key}',
        ),
      );
    }
    return items;
  }

  _DraftGroupItem _buildMigratedConceptPageDraftItem(
    _LinkedTextbook book,
    List<_SelectedMigratedConceptPage> selectedPages, {
    required String draftKey,
  }) {
    final first = selectedPages.first;
    final pages = selectedPages
        .map((page) => page.displayPage)
        .where((page) => page > 0)
        .toSet();
    final sortedPages = pages.toList()..sort();
    final pageText = _pagesToCompactText(pages);
    final pageCounts = <String, int>{
      for (final page in sortedPages) '$page': 0,
    };
    final unitSubKey = _explorerSmallSubKey(first.smallKey);
    final mapping = <String, dynamic>{
      'selectionMode': 'page',
      'sourceScope': 'migrated_concept_pages',
      'bigOrder': first.bigOrder,
      'midOrder': first.midOrder,
      'smallOrder': first.smallOrder,
      'subKey': unitSubKey.isNotEmpty ? unitSubKey : first.smallKey,
      'displaySubKey': unitSubKey.isNotEmpty ? unitSubKey : first.smallKey,
      'bigName': first.bigName,
      'midName': first.midName,
      'smallName': first.smallName,
      'pageCounts': pageCounts,
      'startPage': sortedPages.isEmpty ? null : sortedPages.first,
      'endPage': sortedPages.isEmpty ? null : sortedPages.last,
      'pageCoordinate': 'display',
      'pageCount': sortedPages.length,
      'problemCount': 0,
      'problemNumbers': const <String>[],
      'problemCrops': const <Map<String, dynamic>>[],
      'problemStage': _migratedProblemStageCode,
      'weight': 1.0,
    };
    final pathSummary = [
      first.bigName,
      first.midName,
      first.smallName,
    ].where((value) => '$value'.trim().isNotEmpty).join(' > ');
    return _assembleSubtaskDraftItem(
      book: book,
      title: '${first.smallName}'.trim().isEmpty
          ? '개념 페이지'
          : '${first.smallName}'.trim(),
      page: pageText,
      count: '0',
      pathSummary: pathSummary,
      sourceUnitLevel: 'page',
      sourceUnitPath: '${first.smallName}'.trim(),
      unitMappings: <Map<String, dynamic>>[mapping],
      draftKey: draftKey,
      recommendedMinutes: 0,
    );
  }

  /// 개념원리는 crop.sub_key(A~E) ≠ 소단원(U*) 이므로 이름·페이지로 소단원을 찾는다.
  _SmallUnitSelectionNode? _resolveSmallNodeForRegions(
    List<_TextbookProblemRegion> regions,
    Map<String, _SmallUnitSelectionNode> smallNodes,
  ) {
    if (regions.isEmpty) return null;
    final first = regions.first;
    final bySub =
        smallNodes['${first.bigOrder}|${first.midOrder}|${first.subKey}'];
    if (bySub != null) return bySub;

    final smallName = first.smallName.trim();
    if (smallName.isNotEmpty) {
      for (final entry in smallNodes.entries) {
        if (!entry.key.startsWith('${first.bigOrder}|${first.midOrder}|')) {
          continue;
        }
        if (entry.value.name.trim() == smallName) return entry.value;
      }
    }

    final pages = regions.map((e) => e.displayPage).where((p) => p > 0);
    for (final page in pages) {
      for (final entry in smallNodes.entries) {
        if (!entry.key.startsWith('${first.bigOrder}|${first.midOrder}|')) {
          continue;
        }
        final small = entry.value;
        final start = small.startPage;
        if (start == null) continue;
        final end = small.endPage ?? start;
        if (page >= start && page <= end) return small;
      }
    }
    return null;
  }

  _DraftGroupItem _buildProblemSubtaskDraftItem(
    _LinkedTextbook book,
    List<_TextbookProblemRegion> regions,
    _SmallUnitSelectionNode? smallNode, {
    String? draftKey,
    Set<int> extraConceptPages = const <int>{},
  }) {
    final pages = regions.map((region) => region.displayPage).toSet()
      ..addAll(extraConceptPages.where((page) => page > 0));
    final pageText = _pagesToCompactText(pages);
    final byPage = <int, int>{};
    for (final region in regions) {
      byPage[region.displayPage] = (byPage[region.displayPage] ?? 0) + 1;
    }
    for (final page in extraConceptPages) {
      if (page > 0) byPage.putIfAbsent(page, () => 0);
    }
    final groupLabels = <String>[];
    for (final region in regions) {
      final label = region.typeGroupLabel.trim();
      if (label.isNotEmpty && !groupLabels.contains(label)) {
        groupLabels.add(label);
      }
    }
    final first = regions.first;
    final smallName = (smallNode?.name ?? first.smallName).trim();
    final midName = first.midName.trim();
    final typeTitle = first.typeTitle.trim();
    final isSsenLike = _isSsenLikeLinkedBook(book);
    final isRpm = _isRpmLinkedBook(book);
    final isWonri = _isWonriLinkedBook(book) || first.isWonri;
    final wonriTypeName = isWonri ? first.wonriTypeName : '';
    final rpmSectionTitle = isRpm ? _rpmSpecialSectionTitle(first) : null;
    // 쎈·RPM·개념원리: 하위과제명은 유형/섹션명. 그 외는 소단원명 우선.
    final String title;
    if (rpmSectionTitle != null) {
      title = rpmSectionTitle;
    } else if (isSsenLike) {
      if (typeTitle.isNotEmpty) {
        title = typeTitle;
      } else if (groupLabels.isNotEmpty) {
        title = groupLabels.first;
      } else if (smallName.isNotEmpty) {
        title = smallName;
      } else {
        title = '유형별 문항 ${regions.length}개';
      }
    } else if (isWonri) {
      if (wonriTypeName.isNotEmpty) {
        title = wonriTypeName;
      } else if (groupLabels.isNotEmpty) {
        title = groupLabels.first;
      } else if (smallName.isNotEmpty) {
        title = smallName;
      } else {
        title = '유형별 문항 ${regions.length}개';
      }
    } else {
      title = smallName.isNotEmpty
          ? smallName
          : (groupLabels.length == 1
              ? groupLabels.first
              : '유형별 문항 ${regions.length}개');
    }
    final pathTypeLabel = rpmSectionTitle ??
        (isSsenLike && typeTitle.isNotEmpty ? typeTitle : '');
    final pathSummary = [
      first.bigName,
      midName,
      if (smallName.isNotEmpty) smallName,
      if (pathTypeLabel.isNotEmpty) pathTypeLabel,
      if (isWonri && wonriTypeName.isNotEmpty) wonriTypeName,
    ].where((e) => e.trim().isNotEmpty).join(' > ');
    final mapping = <String, dynamic>{
      'selectionMode': 'problem',
      'sourceScope': 'problem_regions',
      'bigOrder': first.bigOrder,
      'midOrder': first.midOrder,
      if (smallNode != null) 'smallOrder': smallNode.orderIndex,
      'subKey': first.subKey,
      if (smallNode != null) 'displaySubKey': smallNode.subKey,
      'bigName': first.bigName,
      'midName': midName,
      'smallName': smallName,
      'pageCounts': Map<String, int>.fromEntries(
        byPage.entries.map((entry) => MapEntry('${entry.key}', entry.value)),
      ),
      'startPage': pages.isEmpty ? null : pages.reduce(math.min),
      'endPage': pages.isEmpty ? null : pages.reduce(math.max),
      'pageCoordinate': 'display',
      'pageCount': regions.length,
      'problemCount': regions.length,
      'problemNumbers': regions.map((e) => e.problemNumber).toList(),
      'problemCrops': regions.map((e) => e.toMappingJson()).toList(),
      'problemStage': _migratedProblemStageCode,
      'typeGroups': groupLabels,
      if (isWonri && wonriTypeName.isNotEmpty) 'wonriTypeName': wonriTypeName,
      if (rpmSectionTitle != null) 'rpmSectionTitle': rpmSectionTitle,
      'weight': 1.0,
    };
    // 개념원리: 표시용 page 는 비우고, pageCounts/problemCrops 로 페이지·통계를 유지.
    final storedPage = isWonri ? '' : pageText;
    final sourceUnitPath = rpmSectionTitle != null
        ? rpmSectionTitle
        : (isSsenLike
            ? (typeTitle.isNotEmpty
                ? typeTitle
                : (groupLabels.isNotEmpty ? groupLabels.join(', ') : smallName))
            : (isWonri
                ? (wonriTypeName.isNotEmpty
                    ? wonriTypeName
                    : (groupLabels.isNotEmpty
                        ? groupLabels.join(', ')
                        : smallName))
                : (smallName.isNotEmpty
                    ? smallName
                    : (groupLabels.join(', ')))));
    return _assembleSubtaskDraftItem(
      book: book,
      title: title,
      page: storedPage,
      count: '${regions.length}',
      pathSummary: pathSummary,
      sourceUnitLevel: 'problem',
      sourceUnitPath: sourceUnitPath,
      unitMappings: <Map<String, dynamic>>[mapping],
      draftKey: draftKey,
      recommendedMinutes: _estimateRecommendedMinutesForRegions(book, regions),
    );
  }

  /// 자동 하위과제 항목을 입력 폼의 양식/색/시험 설정과 함께 조립한다.
  _DraftGroupItem _assembleSubtaskDraftItem({
    required _LinkedTextbook book,
    required String title,
    required String page,
    required String count,
    required String pathSummary,
    required String sourceUnitLevel,
    required String sourceUnitPath,
    required List<Map<String, dynamic>> unitMappings,
    String? draftKey,
    int? recommendedMinutes,
  }) {
    final testMode = _isCurrentHomeworkTypeTest();
    final timeLimitMinutes =
        testMode ? _parsePositiveIntText(_timeLimitMinutes.text) : null;
    final type = _linkedHomeworkType;
    final color = _colorForType(type);
    final content = '${_bookMetaText(book)}\n$pathSummary';
    final normalizedPage = _normalizePageTextCompact(page);
    // 문항 분류 기반 계산값이 없으면 문항수/페이지수로 폴백.
    final resolvedRecommended = recommendedMinutes ??
        _estimateRecommendedMinutesForCount(
          book,
          count: _parsePositiveIntText(count),
          pageText: normalizedPage,
        );
    return _DraftGroupItem(
      key: draftKey ?? 'draft_${_draftGroupItemSeq++}',
      type: type,
      title: title,
      page: normalizedPage,
      count: count,
      memo: _memo.text.trim(),
      content: content,
      body: _composeBodyValues(
        page: normalizedPage,
        count: count,
        content: content,
        timeLimitMinutes: timeLimitMinutes,
      ),
      color: color,
      // 자동 하위과제는 물리 분할이므로 시간 분할(splitParts)은 1로 둔다.
      // (하위과제 개수가 1개면 호출부에서 사용자가 고른 splitParts를 복원한다.)
      splitParts: 1,
      linkedBookKey: _bookIdentity(book),
      bookId: book.bookId,
      gradeLabel: book.gradeLabel,
      sourceUnitLevel: sourceUnitLevel,
      sourceUnitPath: sourceUnitPath,
      unitMappings: unitMappings,
      timeLimitMinutes: timeLimitMinutes,
      recommendedMinutes: resolvedRecommended,
      recommendedMinutesAuto: resolvedRecommended,
      testMode: testMode,
      testOriginFlowId: testMode ? _currentTestOriginFlowId() : null,
    );
  }

  String _autoSelectionFingerprint() {
    if (_rangePickerMode == 'type') {
      final ids = _selectedProblemRegionIds.toList()..sort();
      final conceptPages = _selectedMigratedConceptPages()
          .map((page) => '${page.smallKey}#${page.rawPage}')
          .toList()
        ..sort();
      return 'type:${ids.join(',')}|concept:${conceptPages.join(',')}';
    }
    final parts = <String>[];
    for (final big in _units) {
      for (final mid in big.middles) {
        for (final small in mid.smalls) {
          if (small.locked || small.draftBlocked) continue;
          final pages = <int>{};
          if (small.selected) {
            pages.addAll(_smallPages(small));
          } else {
            pages.addAll(small.selectedPages);
          }
          if (pages.isEmpty) continue;
          final sorted = pages.toList()..sort();
          parts.add(
            '${big.orderIndex}|${mid.orderIndex}|${small.orderIndex}:${sorted.join('-')}',
          );
        }
      }
    }
    return 'page:${parts.join(';')}';
  }

  /// 자동 모드: 현재 선택을 소단원별 하위과제 리스트로 반영한다.
  void _syncAutoSubtaskDraftList() {
    if (!_autoSubtaskMode) return;
    if (_useCustomSource || _shouldShowNaesinPanel()) return;
    if (!mounted) return;

    final selectedBook = _selectedLinkedBook;
    if (selectedBook == null || _manualPageMode) {
      if (_draftGroupItems.isEmpty &&
          !_showGroupPanel &&
          _autoDraftFingerprint == null) {
        return;
      }
      setState(() {
        _draftGroupItems.clear();
        _showGroupPanel = false;
        _autoDraftFingerprint = null;
        _applyDraftBlockedStateToUnits(
          _units,
          usedPages: const <int>{},
        );
      });
      return;
    }

    final fingerprint = _autoSelectionFingerprint();
    final next = _buildAutoSubtaskDraftItems(selectedBook);
    if (fingerprint == _autoDraftFingerprint &&
        next.length == _draftGroupItems.length) {
      var sameKeys = true;
      for (var i = 0; i < next.length; i++) {
        if (next[i].key != _draftGroupItems[i].key ||
            next[i].page != _draftGroupItems[i].page ||
            next[i].count != _draftGroupItems[i].count) {
          sameKeys = false;
          break;
        }
      }
      if (sameKeys) return;
    }

    setState(() {
      _autoDraftFingerprint = fingerprint;
      _draftGroupItems
        ..clear()
        ..addAll(next);
      // 자동 모드는 선택이 소스이므로 draftBlocked로 잠그지 않는다.
      _applyDraftBlockedStateToUnits(
        _units,
        usedPages: const <int>{},
      );
    });
    _syncGroupTitleFromDrafts();
  }

  void _deselectUnitsForDraftItem(_DraftGroupItem item) {
    final problemIds = _problemIdsFromMappings(item.unitMappings);
    if (problemIds.isNotEmpty) {
      _selectedProblemRegionIds.removeAll(problemIds);
      return;
    }
    for (final mapping in item.unitMappings) {
      final bigOrder = mapping['bigOrder'];
      final midOrder = mapping['midOrder'];
      final subKey = '${mapping['subKey'] ?? ''}';
      final smallOrder = mapping['smallOrder'];
      final pageCountsRaw = mapping['pageCounts'];
      final pages = <int>{};
      if (pageCountsRaw is Map) {
        for (final key in pageCountsRaw.keys) {
          final page = int.tryParse('$key');
          if (page != null) pages.add(page);
        }
      }
      if (pages.isEmpty) {
        pages.addAll(_pagesFromRawPageText(item.page));
      }
      for (final big in _units) {
        if (bigOrder is num && big.orderIndex != bigOrder.toInt()) continue;
        for (final mid in big.middles) {
          if (midOrder is num && mid.orderIndex != midOrder.toInt()) continue;
          for (final small in mid.smalls) {
            final subKeyMatched = subKey.isNotEmpty && small.subKey == subKey;
            final smallOrderMatched =
                smallOrder is num && small.orderIndex == smallOrder.toInt();
            if (!subKeyMatched && !smallOrderMatched) continue;
            if (pages.isEmpty) {
              small.selected = false;
              small.explicitSelected = false;
              small.selectedPages.clear();
            } else {
              small.selectedPages.removeAll(pages);
              if (small.selectedPages.isEmpty) {
                small.selected = false;
                small.explicitSelected = false;
              }
            }
          }
          mid.selected = _allSmallSelected(mid);
        }
        big.selected = _allMidSelected(big);
      }
    }
  }

  void _refreshRangeAutoDraft() {
    final requestId = ++_rangeAiRequestId;
    final selectedBook = _selectedLinkedBook;
    unawaited(_refreshWonriTimedTestEligibility());
    if (_manualPageMode || selectedBook == null) {
      if (mounted) {
        setState(() {
          _rangeAutoPage = '';
          _rangeAutoCount = '';
          _rangeAutoScope = '-';
          _rangeAutoUnitMappings = const <Map<String, dynamic>>[];
          _rangeAiLoading = false;
        });
      }
      _setControllerText(_rangeTitle, '');
      _setControllerText(_rangeContent, '');
      _syncAutoSubtaskDraftList();
      return;
    }
    if (_rangePickerMode == 'type') {
      final merged = _buildProblemSelectionTask(selectedBook);
      if (merged == null) {
        if (mounted) {
          setState(() {
            _rangeAutoPage = '';
            _rangeAutoCount = '';
            _rangeAutoScope = '-';
            _rangeAutoUnitMappings = const <Map<String, dynamic>>[];
            _rangeAiLoading = false;
          });
        }
        _setControllerText(_rangeTitle, '');
        _setControllerText(_rangeContent, '');
        _syncAutoSubtaskDraftList();
        return;
      }
      if (mounted) {
        setState(() {
          _rangeAutoPage = merged.page;
          _rangeAutoCount = merged.count;
          _rangeAutoScope = merged.sourceUnitPath;
          _rangeAutoUnitMappings = List<Map<String, dynamic>>.from(
            merged.unitMappings.map((e) => Map<String, dynamic>.from(e)),
          );
          _rangeAiLoading = false;
        });
      }
      _setControllerText(_rangeTitle, merged.title);
      _setControllerText(_rangeContent, merged.content);
      _syncAutoSubtaskDraftList();
      return;
    }
    final selected = _sortedSelectedSmallUnits(_selectedSmallUnits());
    if (selected.isEmpty) {
      if (mounted) {
        setState(() {
          _rangeAutoPage = '';
          _rangeAutoCount = '';
          _rangeAutoScope = '-';
          _rangeAutoUnitMappings = const <Map<String, dynamic>>[];
          _rangeAiLoading = false;
        });
      }
      _setControllerText(_rangeTitle, '');
      _setControllerText(_rangeContent, '');
      _syncAutoSubtaskDraftList();
      return;
    }
    final merged = _buildMergedRangeTask(selectedBook);
    if (merged == null) {
      if (mounted) {
        setState(() {
          _rangeAutoPage = '';
          _rangeAutoCount = '';
          _rangeAutoScope = '-';
          _rangeAutoUnitMappings = const <Map<String, dynamic>>[];
          _rangeAiLoading = false;
        });
      }
      _setControllerText(_rangeTitle, '');
      _setControllerText(_rangeContent, '');
      _syncAutoSubtaskDraftList();
      return;
    }
    if (mounted) {
      final shouldRunAiSummary = merged.allowAiSummaryTitle;
      setState(() {
        _rangeAutoPage = merged.page;
        _rangeAutoCount = merged.count;
        _rangeAutoScope = _rangeScopeTextFromSelected(selected);
        _rangeAutoUnitMappings = List<Map<String, dynamic>>.from(
          merged.unitMappings.map((e) => Map<String, dynamic>.from(e)),
        );
        _rangeAiLoading = shouldRunAiSummary;
      });
    }
    _setControllerText(_rangeTitle, merged.title);
    _setControllerText(_rangeContent, merged.content);
    if (merged.allowAiSummaryTitle) {
      unawaited(
        _applyAiSummaryForMultiSelection(
          requestId: requestId,
          book: selectedBook,
          selected: selected,
        ),
      );
    }
    _syncAutoSubtaskDraftList();
  }

  void _syncLinkedHomeworkTypeToLinkedDraftItems(String type) {
    final color = _colorForType(type);
    for (var i = 0; i < _draftGroupItems.length; i++) {
      final e = _draftGroupItems[i];
      final key = e.linkedBookKey;
      if (key != null && key.isNotEmpty) {
        _draftGroupItems[i] = e.copyWith(type: type, color: color);
      }
    }
  }

  Widget _buildHomeworkTypeDropdown() {
    final hasBookSelection = _selectedLinkedBookKey != null;
    final fixedPrintType = _useNaesinSource;
    final currentType = fixedPrintType
        ? '프린트'
        : (hasBookSelection ? _linkedHomeworkType : _type);
    final fallbackType = hasBookSelection ? '교재' : '프린트';
    final safe =
        _homeworkTypeValues.contains(currentType) ? currentType : fallbackType;
    return DropdownButtonFormField<String>(
      value: safe,
      items: [
        for (final t in _homeworkTypeValues)
          DropdownMenuItem<String>(value: t, child: Text(t)),
      ],
      onChanged: fixedPrintType
          ? null
          : (v) {
              final next = v ?? fallbackType;
              setState(() {
                if (hasBookSelection) {
                  _linkedHomeworkType = next;
                  _syncLinkedHomeworkTypeToLinkedDraftItems(next);
                } else {
                  _type = next;
                }
              });
            },
      decoration: _inputDecoration('과제 양식'),
      dropdownColor: kDlgPanelBg,
      style: const TextStyle(color: kDlgText, fontWeight: FontWeight.w600),
      iconEnabledColor: kDlgTextSub,
    );
  }

  Widget _buildMigratedProblemStageDropdown() {
    final safe = _migratedProblemStageEnabled.contains(_migratedProblemStage)
        ? _migratedProblemStage
        : _migratedProblemStageValues.first;
    return DropdownButtonFormField<String>(
      value: safe,
      items: [
        for (final t in _migratedProblemStageValues)
          DropdownMenuItem<String>(
            value: t,
            enabled: _migratedProblemStageEnabled.contains(t),
            child: Text(
              _migratedProblemStageEnabled.contains(t) ? t : '$t (준비 중)',
              style: TextStyle(
                color: _migratedProblemStageEnabled.contains(t)
                    ? kDlgText
                    : kDlgTextSub.withOpacity(0.5),
              ),
            ),
          ),
      ],
      onChanged: (v) {
        if (v == null) return;
        if (!_migratedProblemStageEnabled.contains(v)) return;
        setState(() => _migratedProblemStage = v);
      },
      decoration: _inputDecoration('단계'),
      dropdownColor: kDlgPanelBg,
      style: const TextStyle(color: kDlgText, fontWeight: FontWeight.w600),
      iconEnabledColor: kDlgTextSub,
    );
  }

  Widget _buildUnlinkedFlowMode() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _title,
          style: const TextStyle(color: kDlgText, fontWeight: FontWeight.w600),
          decoration: _inputDecoration('하위 과제명', hint: '예: 프린트 1장'),
        ),
        const SizedBox(height: 14),
        _buildManualPageInputs(),
      ],
    );
  }

  Widget _buildPickerChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    final borderColor = selected ? kDlgAccent.withOpacity(0.9) : kDlgBorder;
    final bgColor = selected ? const Color(0x1A33A373) : kDlgFieldBg;
    return Opacity(
      opacity: enabled ? 1.0 : 0.52,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: enabled ? onTap : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(20),
              border:
                  Border.all(color: borderColor, width: selected ? 1.4 : 1.0),
            ),
            child: LatexTextRenderer(
              label,
              style: TextStyle(
                color: enabled
                    ? (selected ? kDlgText : kDlgTextSub)
                    : const Color(0xFF7D8B8B),
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                fontSize: 13.8,
              ),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTreeCheckbox({
    required bool value,
    required ValueChanged<bool?>? onChanged,
    bool disabled = false,
  }) {
    final isDisabled = disabled || onChanged == null;
    return SizedBox(
      width: 22,
      height: 22,
      child: Checkbox(
        value: value,
        onChanged: onChanged,
        activeColor: isDisabled ? const Color(0xFF3A4448) : kDlgAccent,
        checkColor: isDisabled ? const Color(0xFF9FB3B3) : Colors.white,
        fillColor: MaterialStateProperty.resolveWith((states) {
          if (isDisabled) {
            return value ? const Color(0xFF2F3A3E) : const Color(0xFF1F282C);
          }
          if (states.contains(MaterialState.selected)) return kDlgAccent;
          return null;
        }),
        side: BorderSide(
            color: isDisabled ? const Color(0xFF3A4448) : kDlgBorder),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
      ),
    );
  }

  Widget _buildNoticeCard(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: kDlgPanelBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kDlgBorder),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: kDlgTextSub,
          fontSize: 12.5,
          height: 1.35,
        ),
      ),
    );
  }

  Widget _buildManualPageInputs() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _page,
                keyboardType: TextInputType.text,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9\-~,/ ]')),
                ],
                style: const TextStyle(
                    color: kDlgText, fontWeight: FontWeight.w600),
                decoration: _inputDecoration('페이지', hint: '예: 10-12'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _count,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: const TextStyle(
                    color: kDlgText, fontWeight: FontWeight.w600),
                decoration: _inputDecoration('문항수', hint: '예: 12'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _memo,
          minLines: 2,
          maxLines: 4,
          style: const TextStyle(color: kDlgText),
          decoration: _inputDecoration('메모', hint: '예: 홀수 번호만 풀기'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _content,
          minLines: 2,
          maxLines: 4,
          style: const TextStyle(color: kDlgText),
          decoration: _inputDecoration('내용', hint: '필요한 추가 내용을 적어주세요'),
        ),
      ],
    );
  }

  void _showDialogSnackBar(String message) {
    if (!mounted) return;
    showAppSnackBar(context, message, useRoot: true);
  }

  _DraftGroupItem? _buildDraftGroupItemFromInput() {
    final selectedBook = _selectedLinkedBook;
    final useRangeDraft = selectedBook != null && !_manualPageMode;
    final rangeTask =
        useRangeDraft ? _buildMergedRangeTask(selectedBook) : null;
    final title = useRangeDraft ? _rangeTitle.text.trim() : _title.text.trim();
    if (title.isEmpty) return null;
    final rawPage = useRangeDraft ? _rangeAutoPage.trim() : _page.text.trim();
    final page = _normalizePageTextCompact(rawPage);
    final count = useRangeDraft ? _rangeAutoCount.trim() : _count.text.trim();
    final testMode = _isCurrentHomeworkTypeTest();
    final timeLimitMinutes =
        testMode ? _parsePositiveIntText(_timeLimitMinutes.text) : null;
    final content =
        useRangeDraft ? _rangeContent.text.trim() : _content.text.trim();
    final memo = _memo.text.trim();
    final type = selectedBook != null ? _linkedHomeworkType : _type;
    final color = _colorForType(type);
    final unitMappings = selectedBook == null
        ? const <Map<String, dynamic>>[]
        : List<Map<String, dynamic>>.from(
            (rangeTask?.unitMappings ?? _rangeAutoUnitMappings)
                .map((e) => Map<String, dynamic>.from(e)),
          );
    final sourceUnitLevel = selectedBook == null
        ? null
        : (useRangeDraft ? (rangeTask?.sourceUnitLevel ?? 'merged') : 'manual');
    final sourceUnitPath = selectedBook == null
        ? null
        : (useRangeDraft ? rangeTask?.sourceUnitPath : null);
    final int? recommendedMinutes = () {
      if (useRangeDraft && _rangePickerMode == 'type') {
        final regions = _selectedProblemRegions();
        if (regions.isNotEmpty) {
          return _estimateRecommendedMinutesForRegions(selectedBook, regions);
        }
      }
      return _estimateRecommendedMinutesForCount(
        selectedBook,
        count: _parsePositiveIntText(count),
        pageText: page,
      );
    }();
    return _DraftGroupItem(
      key: 'draft_${_draftGroupItemSeq++}',
      type: type,
      title: title,
      page: page,
      count: count,
      memo: memo,
      content: content,
      body: _composeBodyValues(
        page: page,
        count: count,
        content: content,
        timeLimitMinutes: timeLimitMinutes,
      ),
      color: color,
      splitParts: _defaultSplitParts,
      linkedBookKey: _bookIdentity(selectedBook),
      bookId: selectedBook?.bookId ?? '',
      gradeLabel: selectedBook?.gradeLabel ?? '',
      sourceUnitLevel: sourceUnitLevel,
      sourceUnitPath: sourceUnitPath,
      unitMappings: unitMappings,
      timeLimitMinutes: timeLimitMinutes,
      recommendedMinutes: recommendedMinutes,
      recommendedMinutesAuto: recommendedMinutes,
      testMode: testMode,
      testOriginFlowId: testMode ? _currentTestOriginFlowId() : null,
    );
  }

  void _addAutoSubtaskDraftItems(_LinkedTextbook book) {
    final built = _buildAutoSubtaskDraftItems(book);
    if (built.isEmpty) {
      _showDialogSnackBar(
        _rangePickerMode == 'type'
            ? '문항을 1개 이상 선택하세요.'
            : '대/중/소단원을 1개 이상 선택하세요.',
      );
      return;
    }
    // 하위과제가 1개뿐이면 사용자가 고른 시간 분할(splitParts)을 그대로 둔다.
    final items = built.length == 1
        ? <_DraftGroupItem>[
            built.first.copyWith(splitParts: _defaultSplitParts),
          ]
        : built;

    final usedPages = _draftUsedPages();
    final usedProblemIds = _draftUsedProblemIds();
    final incomingProblemIds = <String>{};
    final incomingPages = <int>{};
    for (final item in items) {
      incomingProblemIds.addAll(_problemIdsFromMappings(item.unitMappings));
      incomingPages.addAll(_pagesFromRawPageText(item.page));
    }
    if (incomingProblemIds.isNotEmpty &&
        incomingProblemIds.intersection(usedProblemIds).isNotEmpty) {
      _showDialogSnackBar('이미 추가된 문항이 포함되어 있습니다. 문항을 다시 선택하세요.');
      return;
    }
    if (incomingProblemIds.isEmpty &&
        _hasPageOverlap(incomingPages, usedPages)) {
      _showDialogSnackBar('이미 추가된 페이지가 포함되어 있습니다. 범위를 다시 선택하세요.');
      return;
    }

    setState(() {
      _draftGroupItems.addAll(items);
      _showGroupPanel = true;
      _applyDraftBlockedStateToUnits(
        _units,
        usedPages: _draftUsedPages(),
      );
    });
    _resetRangeSelectionAfterAdd();
    _timeLimitMinutes.clear();
    _memo.clear();
    _syncGroupTitleFromDrafts();
  }

  void _addDraftGroupItemFromInput() {
    final selectedBook = _selectedLinkedBook;
    final useRangeDraft = selectedBook != null && !_manualPageMode;
    final draftBookKey = _currentDraftBookKey();
    final nextBookKey = _bookIdentity(selectedBook);
    if (_draftGroupItems.isNotEmpty && draftBookKey != nextBookKey) {
      _showDialogSnackBar('그룹 과제는 한 교재 범위에서만 추가할 수 있습니다.');
      return;
    }
    if (useRangeDraft) {
      _addAutoSubtaskDraftItems(selectedBook);
      return;
    }
    _DraftGroupItem? item = _buildDraftGroupItemFromInput();
    if (item == null) {
      _showDialogSnackBar('과제명을 입력하세요.');
      return;
    }
    final usedPages = _draftUsedPages();
    final incomingPages = _pagesFromRawPageText(item.page);
    if (selectedBook != null && incomingPages.isNotEmpty) {
      final incomingProblemIds = _problemIdsFromMappings(item.unitMappings);
      final usedProblemIds = _draftUsedProblemIds();
      if (useRangeDraft &&
          incomingProblemIds.isNotEmpty &&
          incomingProblemIds.intersection(usedProblemIds).isNotEmpty) {
        _showDialogSnackBar('이미 추가된 문항이 포함되어 있습니다. 문항을 다시 선택하세요.');
        return;
      }
      if (useRangeDraft &&
          incomingProblemIds.isEmpty &&
          _hasPageOverlap(incomingPages, usedPages)) {
        _showDialogSnackBar('이미 추가된 페이지가 포함되어 있습니다. 범위를 다시 선택하세요.');
        return;
      }
      if (!useRangeDraft) {
        final filteredPages = incomingPages.difference(usedPages);
        if (filteredPages.isEmpty) {
          _showDialogSnackBar('이미 추가된 페이지입니다.');
          return;
        }
        if (filteredPages.length != incomingPages.length) {
          final normalizedPage = _pagesToCompactText(filteredPages);
          item = item.copyWith(
            page: normalizedPage,
            body: _composeBodyValues(
              page: normalizedPage,
              count: item.count,
              content: item.content,
              timeLimitMinutes: item.timeLimitMinutes,
            ),
          );
        }
      }
    }
    final _DraftGroupItem draftItem = item;
    setState(() {
      _draftGroupItems.add(draftItem);
      _showGroupPanel = true;
      _applyDraftBlockedStateToUnits(
        _units,
        usedPages: _draftUsedPages(),
      );
    });
    _resetRangeSelectionAfterAdd();
    if (!useRangeDraft) {
      _title.clear();
      _page.clear();
      _count.clear();
      _content.clear();
    }
    _timeLimitMinutes.clear();
    _memo.clear();
    _syncGroupTitleFromDrafts();
  }

  void _reorderDraftGroupItems(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex -= 1;
      final moved = _draftGroupItems.removeAt(oldIndex);
      _draftGroupItems.insert(newIndex, moved);
    });
  }

  Future<void> _editDraftGroupItem(int index) async {
    if (index < 0 || index >= _draftGroupItems.length) return;
    final source = _draftGroupItems[index];
    final titleController = ImeAwareTextEditingController(text: source.title);
    final pageController = ImeAwareTextEditingController(text: source.page);
    final countController = ImeAwareTextEditingController(text: source.count);
    final timeLimitController = ImeAwareTextEditingController(
      text: source.timeLimitMinutes?.toString() ?? '',
    );
    final recommendedController = ImeAwareTextEditingController(
      text: source.recommendedMinutes?.toString() ?? '',
    );
    final memoController = ImeAwareTextEditingController(text: source.memo);
    final contentController =
        ImeAwareTextEditingController(text: source.content);
    final linkedDraftKey = (source.linkedBookKey ?? '').trim();
    final isNaesinDraft = linkedDraftKey.startsWith(_kNaesinDraftLinkPrefix);
    final isLinkedTextbookDraft = linkedDraftKey.isNotEmpty && !isNaesinDraft;
    var type = source.type;
    try {
      final submitted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              backgroundColor: kDlgBg,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              title: const Text(
                '하위과제 편집',
                style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900),
              ),
              content: SizedBox(
                width: 500,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (isLinkedTextbookDraft) ...[
                        Text(
                          '과제 양식: ${_homeworkTypeValues.contains(_linkedHomeworkType) ? _linkedHomeworkType : '교재'}',
                          style: const TextStyle(
                            color: kDlgText,
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          '연결 교재 그룹은 오른쪽 「그룹 과제 정보」에서 과제 양식을 바꿀 수 있습니다.',
                          style: TextStyle(
                            color: kDlgTextSub,
                            fontSize: 12.3,
                            height: 1.35,
                          ),
                        ),
                        const SizedBox(height: 10),
                      ] else if (isNaesinDraft) ...[
                        const Text(
                          '과제 양식: 프린트',
                          style: TextStyle(
                            color: kDlgText,
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          '내신 셀 과제는 내신 기출 출처로 고정됩니다.',
                          style: TextStyle(
                            color: kDlgTextSub,
                            fontSize: 12.3,
                            height: 1.35,
                          ),
                        ),
                        const SizedBox(height: 10),
                      ] else ...[
                        DropdownButtonFormField<String>(
                          value:
                              _homeworkTypeValues.contains(type) ? type : '프린트',
                          items: [
                            for (final t in _homeworkTypeValues)
                              DropdownMenuItem<String>(
                                  value: t, child: Text(t)),
                          ],
                          onChanged: (v) => setDialogState(() {
                            type = v ?? '프린트';
                          }),
                          decoration: _inputDecoration('과제 양식'),
                          dropdownColor: kDlgPanelBg,
                          style: const TextStyle(
                            color: kDlgText,
                            fontWeight: FontWeight.w600,
                          ),
                          iconEnabledColor: kDlgTextSub,
                        ),
                        const SizedBox(height: 10),
                      ],
                      TextField(
                        controller: titleController,
                        style: const TextStyle(
                          color: kDlgText,
                          fontWeight: FontWeight.w600,
                        ),
                        decoration: _inputDecoration('과제명'),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: pageController,
                              keyboardType: TextInputType.text,
                              inputFormatters: [
                                FilteringTextInputFormatter.allow(
                                  RegExp(r'[0-9\-~,/ ]'),
                                ),
                              ],
                              style: const TextStyle(
                                color: kDlgText,
                                fontWeight: FontWeight.w600,
                              ),
                              decoration:
                                  _inputDecoration('페이지', hint: '예: 10-12'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: countController,
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                              ],
                              style: const TextStyle(
                                color: kDlgText,
                                fontWeight: FontWeight.w600,
                              ),
                              decoration:
                                  _inputDecoration('문항수', hint: '예: 12'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: recommendedController,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        style: const TextStyle(
                          color: kDlgText,
                          fontWeight: FontWeight.w600,
                        ),
                        decoration: _inputDecoration(
                          '권장시간(분)',
                          hint: source.recommendedMinutesAuto != null
                              ? '자동 제안 ${source.recommendedMinutesAuto}분'
                              : '예: 30',
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: memoController,
                        minLines: 2,
                        maxLines: 4,
                        style: const TextStyle(color: kDlgText),
                        decoration: _inputDecoration('메모'),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: contentController,
                        minLines: 2,
                        maxLines: 4,
                        style: const TextStyle(color: kDlgText),
                        decoration: _inputDecoration('내용'),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
                  child: const Text('취소'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
                  child: const Text('저장'),
                ),
              ],
            );
          },
        ),
      );

      if (submitted != true) return;
      final title = titleController.text.trim();
      if (title.isEmpty) {
        _showDialogSnackBar('과제명을 입력하세요.');
        return;
      }
      final page = _normalizePageTextCompact(pageController.text);
      final count = countController.text.trim();
      final timeLimitMinutes = _parsePositiveIntText(timeLimitController.text);
      final recommendedMinutes =
          _parsePositiveIntText(recommendedController.text);
      final memo = memoController.text.trim();
      final content = contentController.text.trim();
      final resolvedType = isLinkedTextbookDraft
          ? (_homeworkTypeValues.contains(_linkedHomeworkType)
              ? _linkedHomeworkType
              : '교재')
          : (isNaesinDraft ? '프린트' : type);
      final updated = source.copyWith(
        type: resolvedType,
        title: title,
        page: page,
        count: count,
        memo: memo,
        content: content,
        body: _composeBodyValues(
          page: page,
          count: count,
          content: content,
          timeLimitMinutes: timeLimitMinutes,
        ),
        color: _colorForType(resolvedType),
        splitParts: _defaultSplitParts,
        timeLimitMinutes:
            (source.testMode || isNaesinDraft) ? timeLimitMinutes : null,
        recommendedMinutes: recommendedMinutes,
        testMode: source.testMode || isNaesinDraft,
      );
      final otherPages = _draftUsedPages(excludingDraftKey: source.key);
      final updatedPages = _pagesFromRawPageText(updated.page);
      if (updatedPages.isNotEmpty &&
          _hasPageOverlap(updatedPages, otherPages)) {
        _showDialogSnackBar('다른 하위 과제와 페이지가 중복됩니다.');
        return;
      }
      setState(() {
        _draftGroupItems[index] = updated;
        _applyDraftBlockedStateToUnits(
          _units,
          usedPages: _draftUsedPages(),
        );
      });
      _refreshRangeAutoDraft();
      _syncGroupTitleFromDrafts();
    } finally {
      titleController.dispose();
      pageController.dispose();
      countController.dispose();
      timeLimitController.dispose();
      recommendedController.dispose();
      memoController.dispose();
      contentController.dispose();
    }
  }

  Widget _buildFlowSelectorButtons({required bool enabled}) {
    final selectorEnabled = enabled && !_isChildAddMode;
    final selectedValue =
        widget.flows.any((f) => f.id == _flowId) ? _flowId : null;
    return Opacity(
      opacity: selectorEnabled ? 1.0 : 0.58,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _isChildAddMode
                ? '플로우 고정 (그룹 기준)'
                : (selectorEnabled ? '플로우 선택' : '플로우 선택 (교재 선택 중)'),
            style: const TextStyle(
              color: kDlgTextSub,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          if (widget.flows.isEmpty)
            _buildNoticeCard('등록된 플로우가 없습니다.')
          else
            SizedBox(
              height: 44,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var i = 0; i < widget.flows.length; i++) ...[
                      if (i > 0) const SizedBox(width: 8),
                      _buildPickerChip(
                        label: widget.flows[i].name,
                        selected: widget.flows[i].id == selectedValue,
                        enabled: selectorEnabled,
                        onTap: () async {
                          if (!selectorEnabled) return;
                          if (_draftGroupItems.isNotEmpty) {
                            _showDialogSnackBar(
                              '하위 과제가 있을 때는 플로우를 변경할 수 없습니다.',
                            );
                            return;
                          }
                          final nextId = widget.flows[i].id.trim();
                          if (nextId.isEmpty || nextId == _flowId) return;
                          setState(() {
                            _flowId = nextId;
                            _useNaesinSource = false;
                            _useCustomSource = false;
                            _testOriginFlowId = null;
                            _selectedLinkedBookKey = null;
                            _manualPageMode = false;
                            _units = const <_BigUnitSelectionNode>[];
                            _expandedLeftMidSmallsKey = null;
                          });
                          await _handleFlowChanged(forceNoBookSelection: true);
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEmbeddedDraftList() => _buildDraftGroupItemList();

  Widget _buildDraftGroupItemList() {
    if (_draftGroupItems.isEmpty) {
      return Container(
        width: double.infinity,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        decoration: BoxDecoration(
          color: const Color(0x221C1C1E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: UtilityGlassDialogTokens.borderColor,
            width: 0.5,
          ),
        ),
        child: Text(
          _autoSubtaskMode
              ? '왼쪽에서 범위를 선택하면 하위 과제가 여기에 표시됩니다.'
              : '입력 후 `+ 하위 과제 추가`로 담아 주세요.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: UtilityGlassDialogTokens.iconColor.withValues(alpha: 0.55),
            fontSize: 16,
            fontWeight: FontWeight.w600,
            height: 1.35,
          ),
        ),
      );
    }
    final listView = ReorderableListView.builder(
      buildDefaultDragHandles: false,
      itemCount: _draftGroupItems.length,
      onReorder: _autoSubtaskMode ? (_, __) {} : _reorderDraftGroupItems,
      itemBuilder: (context, index) {
        final item = _draftGroupItems[index];
        final title = item.title.trim().isEmpty ? '(제목 없음)' : item.title.trim();
        final page = item.page.trim();
        final count = item.count.trim();
        final memo = item.memo.trim();
        final content = item.content.trim();
        final limitText =
            item.timeLimitMinutes != null && item.timeLimitMinutes! > 0
                ? ' · ${item.timeLimitMinutes}분'
                : '';
        final recommendedText =
            item.recommendedMinutes != null && item.recommendedMinutes! > 0
                ? ' · 권장 ${item.recommendedMinutes}분'
                : '';
        final summaryLine =
            '${item.type} · ${count.isEmpty ? '-문항' : '${count}문항'}$limitText$recommendedText';
        return Container(
          key: ValueKey('draft_group_item_${item.key}'),
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: const Color(0x221C1C1E),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: UtilityGlassDialogTokens.borderColor,
              width: 0.5,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              key: PageStorageKey<String>('draft_expand_${item.key}'),
              initiallyExpanded: false,
              maintainState: true,
              iconColor: UtilityGlassDialogTokens.iconColor.withValues(
                alpha: 0.7,
              ),
              collapsedIconColor: UtilityGlassDialogTokens.iconColor.withValues(
                alpha: 0.55,
              ),
              tilePadding: const EdgeInsets.fromLTRB(12, 4, 10, 4),
              childrenPadding: const EdgeInsets.fromLTRB(14, 0, 12, 12),
              leading: _autoSubtaskMode
                  ? SizedBox(
                      width: 26,
                      child: Text(
                        '${index + 1}',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: UtilityGlassDialogTokens.iconColor.withValues(
                            alpha: 0.75,
                          ),
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                        ),
                      ),
                    )
                  : ReorderableDragStartListener(
                      index: index,
                      child: Icon(
                        Icons.drag_indicator,
                        color: UtilityGlassDialogTokens.iconColor.withValues(
                          alpha: 0.45,
                        ),
                        size: 20,
                      ),
                    ),
              title: LatexTextRenderer(
                title,
                style: const TextStyle(
                  color: UtilityGlassDialogTokens.iconColor,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
                softWrap: true,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  page.isEmpty ? summaryLine : 'p.$page  ·  $summaryLine',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: UtilityGlassDialogTokens.iconColor.withValues(
                      alpha: 0.55,
                    ),
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (memo.isNotEmpty) ...[
                        LatexTextRenderer(
                          '메모: $memo',
                          style: TextStyle(
                            color: UtilityGlassDialogTokens.iconColor
                                .withValues(alpha: 0.6),
                            fontSize: 16,
                            height: 1.35,
                          ),
                          softWrap: true,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 6),
                      ],
                      if (content.isNotEmpty) ...[
                        LatexTextRenderer(
                          content,
                          style: TextStyle(
                            color: UtilityGlassDialogTokens.iconColor
                                .withValues(alpha: 0.6),
                            fontSize: 16,
                            height: 1.35,
                          ),
                          softWrap: true,
                          maxLines: 6,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 10),
                      ],
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (!_autoSubtaskMode)
                            IconButton(
                              tooltip: '편집',
                              visualDensity: VisualDensity.compact,
                              onPressed: () => _editDraftGroupItem(index),
                              icon: Icon(
                                Icons.edit_outlined,
                                color: UtilityGlassDialogTokens.iconColor
                                    .withValues(alpha: 0.7),
                                size: 20,
                              ),
                            ),
                          IconButton(
                            tooltip: _autoSubtaskMode ? '선택 해제' : '삭제',
                            visualDensity: VisualDensity.compact,
                            onPressed: () {
                              if (_autoSubtaskMode) {
                                setState(() {
                                  _deselectUnitsForDraftItem(item);
                                  _autoDraftFingerprint = null;
                                });
                                _refreshRangeAutoDraft();
                                return;
                              }
                              setState(() {
                                _draftGroupItems.removeAt(index);
                                if (_draftGroupItems.isEmpty) {
                                  _showGroupPanel = false;
                                }
                                _applyDraftBlockedStateToUnits(
                                  _units,
                                  usedPages: _draftUsedPages(),
                                );
                              });
                              _refreshRangeAutoDraft();
                              _syncGroupTitleFromDrafts();
                            },
                            icon: const Icon(
                              Icons.delete_outline_rounded,
                              color: Color(0xFFE57373),
                              size: 20,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    // 마이그레이션 교재는 그룹 제목 아래에 권장시간을 보여 주므로
    // 하위과제 목록 위 합계는 생략한다.
    final isMigrated = _selectedLinkedBook?.isMigrated == true;
    final totalRecommendedMinutes = _draftGroupRecommendedMinutesTotal();
    if (isMigrated || totalRecommendedMinutes <= 0) return listView;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
          child: Text(
            '권장시간 합계 ${_formatMinutesLabel(totalRecommendedMinutes)}',
            textAlign: TextAlign.right,
            style: TextStyle(
              color: UtilityGlassDialogTokens.iconColor.withValues(alpha: 0.7),
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Expanded(child: listView),
      ],
    );
  }

  /// 하위과제 권장시간 합계(분). α는 그룹당 한 번만 반영한다.
  int _draftGroupRecommendedMinutesTotal() {
    final rawRecommendedMinutes = _draftGroupItems.fold<int>(
      0,
      (sum, item) => sum + (item.recommendedMinutes ?? 0),
    );
    final alphaIncludedItemCount = _draftGroupItems
        .where((item) => (item.recommendedMinutesAuto ?? 0) > 0)
        .length;
    return math.max(
      0,
      rawRecommendedMinutes -
          math.max(0, alphaIncludedItemCount - 1) *
              HomeworkTimeDefaultsService.initialAlphaMinutes,
    );
  }

  String _formatMinutesLabel(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h <= 0) return '$m분';
    return m == 0 ? '$h시간' : '$h시간 $m분';
  }

  Widget _buildMigratedGroupSummaryInfo() {
    final pages = _draftUsedPages();
    final pageText = pages.isEmpty ? '-' : 'p.${_pagesToCompactText(pages)}';
    var totalCount = 0;
    for (final item in _draftGroupItems) {
      totalCount += _parsePositiveIntText(item.count) ?? 0;
    }
    final countText = totalCount > 0 ? '${totalCount}문항' : '-';
    final recommended = _draftGroupRecommendedMinutesTotal();
    final recommendedText =
        recommended > 0 ? _formatMinutesLabel(recommended) : '-';

    Widget infoCell(String label, String value) {
      return Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                color: kDlgTextSub.withValues(alpha: 0.85),
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: kDlgText,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );
    }

    return Row(
      children: [
        infoCell('페이지', pageText),
        infoCell('문항수', countText),
        infoCell('권장시간', recommendedText),
      ],
    );
  }

  Widget _buildTestConstraintOptionsCard() {
    Widget optionRow({
      required String title,
      required String subtitle,
      required bool selected,
      required bool enabled,
      required ValueChanged<bool?>? onChanged,
      Widget? trailing,
    }) {
      return Opacity(
        opacity: enabled ? 1 : 0.5,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: selected ? const Color(0x1A33A373) : kDlgFieldBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? kDlgAccent.withValues(alpha: 0.8) : kDlgBorder,
            ),
          ),
          child: Row(
            children: [
              Checkbox(
                value: selected,
                onChanged: enabled ? onChanged : null,
                activeColor: kDlgAccent,
                checkColor: Colors.white,
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: kDlgText,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: kDlgTextSub,
                        fontSize: 12,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 12),
                trailing,
              ],
            ],
          ),
        ),
      );
    }

    final eligibilityText = _timedTestEligibilityLoading
        ? '자동채점 가능 문항을 확인 중입니다.'
        : '선택 문항 $_timedTestEligibleCount개 · 자가채점 제외 $_timedTestExcludedCount개';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0x221C1C1E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: UtilityGlassDialogTokens.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '테스트 제한 옵션',
            style: TextStyle(
              color: kDlgText,
              fontSize: 15,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 10),
          optionRow(
            title: '시간 제한',
            subtitle: '그룹의 모든 하위 테스트에 같은 제한시간을 적용합니다.',
            selected: _testTimeLimitEnabled,
            enabled: true,
            onChanged: (value) {
              setState(() => _testTimeLimitEnabled = value ?? false);
            },
            trailing: SizedBox(
              width: 112,
              child: TextField(
                controller: _timeLimitMinutes,
                enabled: _testTimeLimitEnabled,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: const TextStyle(
                  color: kDlgText,
                  fontWeight: FontWeight.w700,
                ),
                decoration: _inputDecoration('제한시간(분)', hint: '예: 50'),
              ),
            ),
          ),
          const SizedBox(height: 10),
          optionRow(
            title: '문항 수 제한',
            subtitle: '준비 중 · V0는 적격 문항 전체를 출제합니다.',
            selected: false,
            enabled: false,
            onChanged: null,
          ),
          if (_isWonriTimedTestV0Active()) ...[
            const SizedBox(height: 10),
            Text(
              eligibilityText,
              style: TextStyle(
                color: _timedTestEligibleCount > 0
                    ? kDlgTextSub
                    : const Color(0xFFE5A65B),
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildGroupSettingsRow() {
    final groupTitle =
        _groupTitle.text.trim().isEmpty ? '그룹 과제' : _groupTitle.text.trim();
    final showStageDropdown = _selectedLinkedBook?.isMigrated == true;
    final groupTitleField = _isChildAddMode
        ? Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 13,
            ),
            decoration: BoxDecoration(
              color: kDlgPanelBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: kDlgBorder),
            ),
            child: Text(
              '대상 그룹: $groupTitle',
              style: const TextStyle(
                color: kDlgText,
                fontSize: 13.2,
                fontWeight: FontWeight.w700,
              ),
            ),
          )
        : TextField(
            controller: _groupTitle,
            style: const TextStyle(
              color: kDlgText,
              fontWeight: FontWeight.w700,
            ),
            decoration: _inputDecoration(
              '그룹 제목',
              hint: '예: 3월 1주차 과제',
            ),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _buildHomeworkTypeDropdown()),
            if (showStageDropdown) ...[
              const SizedBox(width: 10),
              Expanded(child: _buildMigratedProblemStageDropdown()),
            ],
          ],
        ),
        const SizedBox(height: 12),
        groupTitleField,
        if (showStageDropdown) ...[
          const SizedBox(height: 12),
          _buildMigratedGroupSummaryInfo(),
        ],
      ],
    );
  }

  Widget _buildRangeInlineEditors() {
    const singleLineInputHeight = 58.0;
    const readonlyLineHeight = 20.0;
    const readonlyLineGap = 4.0;
    const contentPreviewHeight = 72.0;
    final hasSelection = _rangeAutoUnitMappings.isNotEmpty;
    final pageText =
        _rangeAutoPage.trim().isEmpty ? '-' : 'p.${_rangeAutoPage.trim()}';
    final countText =
        _rangeAutoCount.trim().isEmpty ? '-' : '${_rangeAutoCount.trim()}문항';
    final scopeText =
        _rangeAutoScope.trim().isEmpty ? '-' : _rangeAutoScope.trim();
    Widget readonlyLine(
      String label,
      String value, {
      int? maxLines,
      TextOverflow overflow = TextOverflow.clip,
    }) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 58,
            child: Text(
              label,
              style: const TextStyle(
                color: kDlgTextSub,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                height: 1.35,
              ),
            ),
          ),
          Expanded(
            child: LatexTextRenderer(
              value,
              style: const TextStyle(
                color: kDlgText,
                fontSize: 13.2,
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
              softWrap: true,
              maxLines: maxLines,
              overflow: overflow,
            ),
          ),
        ],
      );
    }

    Widget boundedReadonlyLine(
      String label,
      String value, {
      required double height,
      int? maxLines,
      TextOverflow overflow = TextOverflow.clip,
    }) {
      return SizedBox(
        height: height,
        child: readonlyLine(
          label,
          value,
          maxLines: maxLines,
          overflow: overflow,
        ),
      );
    }

    Widget readonlyScrollableContentLine(String value) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(
            width: 58,
            child: Text(
              '내용',
              style: TextStyle(
                color: kDlgTextSub,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                height: 1.35,
              ),
            ),
          ),
          Expanded(
            child: SizedBox(
              height: contentPreviewHeight,
              child: Scrollbar(
                controller: _rangeContentScrollController,
                thumbVisibility: false,
                child: SingleChildScrollView(
                  controller: _rangeContentScrollController,
                  child: LatexTextRenderer(
                    value,
                    style: const TextStyle(
                      color: kDlgText,
                      fontSize: 13.2,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                    softWrap: true,
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: singleLineInputHeight,
          child: TextField(
            controller: _rangeTitle,
            enabled: hasSelection,
            style:
                const TextStyle(color: kDlgText, fontWeight: FontWeight.w600),
            decoration: _inputDecoration(
              '하위 과제명',
              hint:
                  hasSelection ? '자동 생성된 과제명을 수정할 수 있어요' : '범위를 선택하면 자동 생성됩니다',
            ),
          ),
        ),
        const SizedBox(height: 10.4),
        SizedBox(
          height: singleLineInputHeight,
          child: TextField(
            controller: _memo,
            enabled: hasSelection,
            minLines: 1,
            maxLines: 1,
            style: const TextStyle(color: kDlgText),
            decoration: _inputDecoration(
              '메모',
              hint: hasSelection ? '예: 홀수 번호만 풀기' : '범위를 선택하면 입력할 수 있어요',
            ),
          ),
        ),
        const SizedBox(height: 6),
        if (_isCurrentHomeworkTypeTest()) ...[
          const SizedBox(height: 10.4),
          SizedBox(
            height: singleLineInputHeight,
            child: TextField(
              controller: _timeLimitMinutes,
              enabled: hasSelection,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: const TextStyle(
                color: kDlgText,
                fontWeight: FontWeight.w600,
              ),
              decoration: _inputDecoration(
                '제한시간(분)',
                hint: hasSelection ? '예: 50' : '범위를 선택하면 입력할 수 있어요',
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        boundedReadonlyLine(
          '범위',
          scopeText,
          height: readonlyLineHeight,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: readonlyLineGap),
        boundedReadonlyLine(
          '페이지',
          '$pageText  ·  $countText',
          height: readonlyLineHeight,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: readonlyLineGap),
        readonlyScrollableContentLine(
          _rangeContent.text.trim().isEmpty
              ? (hasSelection ? '-' : '범위를 선택하면 자동 생성됩니다')
              : _rangeContent.text.trim(),
        ),
        const SizedBox(height: 4),
        if (_rangeAiLoading) ...[
          const SizedBox(height: 4),
          const Text(
            '다중 단원 AI 요약 생성 중...',
            style: TextStyle(
              color: kDlgTextSub,
              fontSize: 11.8,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }

  void _setAutoSubtaskMode(bool enabled) {
    if (_autoSubtaskMode == enabled) return;
    if (enabled) {
      setState(() {
        _autoSubtaskMode = true;
        _autoDraftFingerprint = null;
        _detailsPanelExpanded = false;
        _applyDraftBlockedStateToUnits(
          _units,
          usedPages: const <int>{},
        );
      });
      _syncAutoSubtaskDraftList();
      return;
    }
    setState(() {
      _autoSubtaskMode = false;
      _autoDraftFingerprint = null;
      if (_draftGroupItems.isNotEmpty) {
        _applyDraftBlockedStateToUnits(
          _units,
          usedPages: _draftUsedPages(),
        );
      }
    });
  }

  Future<void> _clearSelectedLinkedBook() async {
    if (_isChildAddMode) return;
    if (_selectedLinkedBookKey == null && !_useNaesinSource) return;
    _disposeMigratedExplorer();
    if (!mounted) return;
    setState(() {
      _selectedLinkedBookKey = null;
      _linkedBookSeriesKey = null;
      _manualPageMode = false;
      _units = const <_BigUnitSelectionNode>[];
      _problemRegions = const <_TextbookProblemRegion>[];
      _selectedProblemRegionIds.clear();
      _expandedLeftMidSmallsKey = null;
      _activeMidKey = null;
      _activeTypeSmallKey = null;
      _pendingScrollSmallExpandKey = null;
      _draftGroupItems.clear();
      _showGroupPanel = false;
      _autoDraftFingerprint = null;
      _rangePickerMode = 'page';
    });
    await _handleFlowChanged(forceNoBookSelection: true);
  }

  Widget _buildBookRangeHeader(_LinkedTextbook book) {
    final title =
        book.bookName.trim().isEmpty ? '(이름 없음)' : book.bookName.trim();
    final grade = book.gradeLabel.trim();
    final subtitle = grade.isEmpty ? null : grade;
    final canGoBack = !_isChildAddMode;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          if (canGoBack) ...[
            Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => unawaited(_clearSelectedLinkedBook()),
                child: Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: kDlgFieldBg,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: kDlgBorder),
                  ),
                  child: const Icon(
                    Icons.arrow_back_rounded,
                    size: 20,
                    color: kDlgText,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kDlgText,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kDlgTextSub,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAutoCheckbox() {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _setAutoSubtaskMode(!_autoSubtaskMode),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: Checkbox(
                value: _autoSubtaskMode,
                activeColor: kDlgAccent,
                side: const BorderSide(color: kDlgBorder, width: 1.4),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
                onChanged: (value) => _setAutoSubtaskMode(value ?? true),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '자동',
              style: TextStyle(
                color: UtilityGlassDialogTokens.iconColor.withValues(
                  alpha: 0.9,
                ),
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 수동 모드(또는 사용자화)에서만 표시. 자동 체크는 타이틀 행에 둔다.
  Widget? _buildManualAddChildButton() {
    if (_autoSubtaskMode && !_useCustomSource) return null;
    final showNaesinPanel = _shouldShowNaesinPanel();
    final showControls = showNaesinPanel ||
        _useCustomSource ||
        _selectedLinkedBookKey != null ||
        _draftGroupItems.isNotEmpty;
    if (!showControls) return null;
    const actionHeight = 40.0;
    if (showNaesinPanel) {
      return Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          height: actionHeight,
          child: OutlinedButton(
            onPressed: () => _showDialogSnackBar('추가할 내신 셀을 클릭하면 하위 과제로 담깁니다.'),
            style: OutlinedButton.styleFrom(
              foregroundColor: kDlgText,
              side: const BorderSide(color: kDlgBorder),
              minimumSize: const Size(0, actionHeight),
              padding: const EdgeInsets.symmetric(horizontal: 16),
            ),
            child: const Text('+ 하위 과제 추가'),
          ),
        ),
      );
    }
    return Align(
      alignment: Alignment.centerRight,
      child: SizedBox(
        height: actionHeight,
        child: OutlinedButton(
          onPressed: (_useCustomSource || _selectedLinkedBookKey != null)
              ? _addDraftGroupItemFromInput
              : null,
          style: OutlinedButton.styleFrom(
            foregroundColor: kDlgText,
            side: const BorderSide(color: kDlgBorder),
            minimumSize: const Size(0, actionHeight),
            padding: const EdgeInsets.symmetric(horizontal: 16),
          ),
          child: const Text('+ 하위 과제 추가'),
        ),
      ),
    );
  }

  void _clearPageUnitSelection() {
    for (final big in _units) {
      big.selected = false;
      big.explicitSelected = false;
      for (final mid in big.middles) {
        mid.selected = false;
        mid.explicitSelected = false;
        for (final small in mid.smalls) {
          small.selected = false;
          small.explicitSelected = false;
          small.selectedPages.clear();
        }
      }
    }
  }

  void _selectPagesFromPageInput() {
    final pages = _pagesFromRawPageText(_page.text);
    if (pages.isEmpty) {
      _showDialogSnackBar('페이지를 입력하세요.');
      return;
    }
    String? nextActiveMidKey;
    var matched = 0;
    setState(() {
      _rangePickerMode = 'page';
      _selectedProblemRegionIds.clear();
      _activeTypeSmallKey = null;
      _clearPageUnitSelection();
      for (final big in _units) {
        for (final mid in big.middles) {
          for (final small in mid.smalls) {
            if (small.locked || small.draftBlocked) continue;
            final selected = pages.intersection(_smallPages(small));
            if (selected.isEmpty) continue;
            small.selectedPages.addAll(selected);
            matched += selected.length;
            nextActiveMidKey ??= _midExpandKey(big, mid);
          }
          mid.selected = _allSmallSelected(mid);
        }
        big.selected = _allMidSelected(big);
      }
      if (nextActiveMidKey != null) {
        _activeMidKey = nextActiveMidKey;
        _expandedLeftMidSmallsKey = nextActiveMidKey;
      }
    });
    if (matched == 0) {
      _showDialogSnackBar('입력한 페이지가 현재 교재 범위에 없습니다.');
    }
    _refreshRangeAutoDraft();
  }

  List<_TextbookProblemRegion> _selectedProblemRegions() {
    if (_selectedProblemRegionIds.isEmpty) {
      return const <_TextbookProblemRegion>[];
    }
    return _problemRegions
        .where((region) =>
            !region.isSetHeader &&
            _selectedProblemRegionIds.contains(region.id))
        .toList(growable: false);
  }

  List<_TypeProblemFlatEntry> _typeProblemFlatEntries(
    _BigUnitSelectionNode big,
    _MidUnitSelectionNode mid,
  ) {
    final activeSmallKey = _activeTypeSmallKey;
    _SmallUnitSelectionNode? activeSmall;
    if (activeSmallKey != null) {
      for (final small in mid.smalls) {
        if (_smallExpandKey(big, mid, small) == activeSmallKey) {
          activeSmall = small;
          break;
        }
      }
    }
    final subKeys = activeSmall == null
        ? mid.smalls.map((small) => small.subKey).toSet()
        : <String>{activeSmall.subKey};
    bool regionInActiveSmall(_TextbookProblemRegion region) {
      if (!mid.isConcept) {
        return subKeys.isEmpty || subKeys.contains(region.subKey);
      }
      // 개념원리: crop.sub_key 는 A~E, 소단원은 U* — 이름·페이지로 매칭.
      if (activeSmall == null) return true;
      final name = region.smallName.trim();
      if (name.isNotEmpty && name == activeSmall.name.trim()) return true;
      final start = activeSmall.startPage;
      if (start == null) return false;
      final end = activeSmall.endPage ?? start;
      return region.displayPage >= start && region.displayPage <= end;
    }

    final regions = _problemRegions
        .where((region) =>
            !region.isSetHeader &&
            region.bigOrder == big.orderIndex &&
            region.midOrder == mid.orderIndex &&
            regionInActiveSmall(region))
        .toList()
      ..sort(_compareTextbookProblemRegionsBySource);
    final book = _selectedLinkedBook;
    String regionKey(_TextbookProblemRegion region) {
      if (book == null) return region.typeGroupKey;
      return _problemSubtaskGroupKey(region, book);
    }

    String regionHeaderLabel(_TextbookProblemRegion region) {
      return _rpmSpecialSectionTitle(region) ?? region.typeGroupLabel;
    }

    final out = <_TypeProblemFlatEntry>[];
    String? currentTypeKey;
    final pageGroups = <int, List<_TextbookProblemRegion>>{};
    for (final region in regions) {
      pageGroups
          .putIfAbsent(region.displayPage, () => <_TextbookProblemRegion>[])
          .add(region);
    }
    for (final page in pageGroups.keys.toList()..sort()) {
      out.add(_TypeProblemFlatEntry.pageHeader(page));
      currentTypeKey = null;
      for (final region in pageGroups[page]!) {
        final groupKey = '${region.displayPage}|${regionKey(region)}';
        if (currentTypeKey != groupKey) {
          currentTypeKey = groupKey;
          final groupRegions = pageGroups[page]!
              .where(
                (e) => '${e.displayPage}|${regionKey(e)}' == groupKey,
              )
              .toList(growable: false);
          out.add(
            _TypeProblemFlatEntry.typeHeader(
              label: regionHeaderLabel(region),
              regions: groupRegions,
            ),
          );
        }
        out.add(_TypeProblemFlatEntry.problem(region));
      }
    }
    return out;
  }

  double _typeProblemEntryHeight(_TypeProblemFlatEntry entry) {
    return entry.isPageHeader
        ? _kMidRightSmallHeaderHeight
        : _kSmallPageListRowStride;
  }

  double _typeProblemFlatContentHeight(List<_TypeProblemFlatEntry> entries) {
    var h = 0.0;
    for (final entry in entries) {
      h += _typeProblemEntryHeight(entry);
    }
    return h;
  }

  int? _typeProblemFlatEntryIndexAtLocalY(
    List<_TypeProblemFlatEntry> entries,
    double localY,
  ) {
    if (localY < 0) return null;
    var y = 0.0;
    for (var i = 0; i < entries.length; i++) {
      final h = _typeProblemEntryHeight(entries[i]);
      if (localY >= y && localY < y + h) return i;
      y += h;
    }
    return null;
  }

  int? _nearestTypeProblemIndexAtLocalY(
    List<_TypeProblemFlatEntry> entries,
    double localY,
  ) {
    var bestDist = double.infinity;
    int? best;
    var y = 0.0;
    for (var i = 0; i < entries.length; i++) {
      final h = _typeProblemEntryHeight(entries[i]);
      if (entries[i].isProblem) {
        final d = (localY - (y + h / 2)).abs();
        if (d < bestDist) {
          bestDist = d;
          best = i;
        }
      }
      y += h;
    }
    return best;
  }

  void _toggleProblemRegionGroup(List<_TextbookProblemRegion> regions) {
    if (regions.isEmpty) return;
    final allSelected = regions
        .every((region) => _selectedProblemRegionIds.contains(region.id));
    setState(() {
      _rangePickerMode = 'type';
      _clearPageUnitSelection();
      if (allSelected) {
        for (final region in regions) {
          _selectedProblemRegionIds.remove(region.id);
        }
      } else {
        for (final region in regions) {
          _selectedProblemRegionIds.add(region.id);
        }
      }
    });
    _refreshRangeAutoDraft();
  }

  void _applyProblemRegionIndexRange(
    List<_TypeProblemFlatEntry> entries,
    int anchorIdx,
    int curIdx,
    bool select,
  ) {
    final baseline = _problemListDragBaseline;
    if (baseline == null) return;
    final problemIndices = <int>[];
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].isProblem) problemIndices.add(i);
    }
    final a = problemIndices.indexOf(anchorIdx);
    final b = problemIndices.indexOf(curIdx);
    if (a < 0 || b < 0) return;
    final lo = math.min(a, b);
    final hi = math.max(a, b);
    final selectedRange = problemIndices.sublist(lo, hi + 1).toSet();
    setState(() {
      _selectedProblemRegionIds
        ..clear()
        ..addAll(baseline);
      for (final idx in selectedRange) {
        final region = entries[idx].region;
        if (region == null) continue;
        if (select) {
          _selectedProblemRegionIds.add(region.id);
        } else {
          _selectedProblemRegionIds.remove(region.id);
        }
      }
    });
    _refreshRangeAutoDraft();
  }

  void _handleRightProblemPointerDown(
    PointerDownEvent e,
    List<_TypeProblemFlatEntry> entries,
  ) {
    final idx = _typeProblemFlatEntryIndexAtLocalY(entries, e.localPosition.dy);
    if (idx == null) return;
    final entry = entries[idx];
    if (entry.isPageHeader) return;
    if (entry.isTypeHeader) {
      _toggleProblemRegionGroup(entry.groupRegions);
      return;
    }
    final region = entry.region;
    if (region == null) return;
    final selectMode = !_selectedProblemRegionIds.contains(region.id);
    setState(() {
      _rightProblemPointerDown = true;
      _rightProblemPointerDownLocal = e.localPosition;
      _rightProblemDragMoved = false;
      _problemListDragAnchorIndex = idx;
      _problemListDragSelectMode = selectMode;
      _problemListDragBaseline = Set<String>.from(_selectedProblemRegionIds);
      if (selectMode) {
        _selectedProblemRegionIds.add(region.id);
      } else {
        _selectedProblemRegionIds.remove(region.id);
      }
    });
    _refreshRangeAutoDraft();
  }

  void _handleRightProblemPointerMove(
    PointerMoveEvent e,
    List<_TypeProblemFlatEntry> entries,
  ) {
    if (!_rightProblemPointerDown ||
        _rightProblemPointerDownLocal == null ||
        _problemListDragAnchorIndex == null ||
        _problemListDragSelectMode == null) {
      return;
    }
    final down = _rightProblemPointerDownLocal!;
    if (!_rightProblemDragMoved && (e.localPosition - down).distance <= 4) {
      return;
    }
    if (!_rightProblemDragMoved) {
      setState(() => _rightProblemDragMoved = true);
    }
    final curIdx =
        _nearestTypeProblemIndexAtLocalY(entries, e.localPosition.dy);
    if (curIdx == null) return;
    _applyProblemRegionIndexRange(
      entries,
      _problemListDragAnchorIndex!,
      curIdx,
      _problemListDragSelectMode!,
    );
  }

  void _handleRightProblemPointerEnd() {
    if (!_rightProblemPointerDown) return;
    setState(() {
      _rightProblemPointerDown = false;
      _rightProblemPointerDownLocal = null;
      _rightProblemDragMoved = false;
      _problemListDragAnchorIndex = null;
      _problemListDragSelectMode = null;
      _problemListDragBaseline = null;
    });
  }

  Widget _buildRightProblemRowMeta({
    required _TextbookProblemRegion region,
  }) {
    return Text(
      region.difficultyLabel,
      style: const TextStyle(
        color: kDlgTextSub,
        fontWeight: FontWeight.w600,
        fontSize: 12.5,
      ),
    );
  }

  Widget _buildRightTypeProblemPanel(
    _BigUnitSelectionNode big,
    _MidUnitSelectionNode mid,
  ) {
    final entries = _typeProblemFlatEntries(big, mid);
    final totalH = _typeProblemFlatContentHeight(entries);
    if (entries.isEmpty || totalH <= 0) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            '이 중단원에 표시할 문항 정보가 없습니다.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: kDlgTextSub,
              fontWeight: FontWeight.w600,
              fontSize: 12.5,
            ),
          ),
        ),
      );
    }

    final rowWidgets = <Widget>[];
    _TypeProblemFlatEntry? prev;
    for (final entry in entries) {
      if (entry.isPageHeader) {
        rowWidgets.add(
          SizedBox(
            height: _kMidRightSmallHeaderHeight,
            child: Container(
              width: double.infinity,
              color: const Color(0x1F0F1518),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.centerLeft,
              child: Text(
                'P.${entry.displayPage}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: kDlgTextSub,
                  fontWeight: FontWeight.w600,
                  fontSize: 12.4,
                  height: 1.15,
                ),
              ),
            ),
          ),
        );
      } else if (entry.isTypeHeader) {
        final group = entry.groupRegions;
        final allSelected = group.isNotEmpty &&
            group.every(
                (region) => _selectedProblemRegionIds.contains(region.id));
        final anySelected = group
            .any((region) => _selectedProblemRegionIds.contains(region.id));
        rowWidgets.add(
          SizedBox(
            height: _kSmallPageListRowStride,
            child: Container(
              decoration: BoxDecoration(
                border: Border(
                  top: prev?.isPageHeader == true
                      ? BorderSide.none
                      : const BorderSide(color: kDlgBorder, width: 1),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.centerLeft,
              child: Row(
                children: [
                  Icon(
                    allSelected
                        ? Icons.check_box_rounded
                        : (anySelected
                            ? Icons.indeterminate_check_box_rounded
                            : Icons.check_box_outline_blank_rounded),
                    size: 22,
                    color: anySelected ? kDlgAccent : kDlgBorder,
                  ),
                  const SizedBox(width: 15),
                  Expanded(
                    child: Text(
                      entry.typeGroupLabel ?? '유형 미분류',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: kDlgTextSub,
                        fontWeight: FontWeight.w700,
                        fontSize: 12.8,
                      ),
                    ),
                  ),
                  Text(
                    '${group.length}문항',
                    style: const TextStyle(
                      color: kDlgTextSub,
                      fontWeight: FontWeight.w600,
                      fontSize: 12.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      } else {
        final region = entry.region!;
        final selected = _selectedProblemRegionIds.contains(region.id);
        final afterHeader =
            prev?.isPageHeader == true || prev?.isTypeHeader == true;
        rowWidgets.add(
          SizedBox(
            height: _kSmallPageListRowStride,
            child: Container(
              decoration: BoxDecoration(
                border: Border(
                  top: afterHeader
                      ? BorderSide.none
                      : const BorderSide(color: kDlgBorder, width: 1),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.centerLeft,
              child: Row(
                children: [
                  Icon(
                    selected
                        ? Icons.check_box_rounded
                        : Icons.check_box_outline_blank_rounded,
                    size: 22,
                    color: selected ? kDlgAccent : kDlgBorder,
                  ),
                  const SizedBox(width: 15),
                  Expanded(
                    child: Text(
                      '${region.problemNumber}번',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: kDlgText,
                        fontWeight: FontWeight.w600,
                        fontSize: 13.2,
                      ),
                    ),
                  ),
                  _buildRightProblemRowMeta(region: region),
                ],
              ),
            ),
          ),
        );
      }
      prev = entry;
    }

    return Scrollbar(
      controller: _rangeRightScrollController,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _rangeRightScrollController,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (ev) =>
                  _handleRightProblemPointerDown(ev, entries),
              onPointerMove: (ev) =>
                  _handleRightProblemPointerMove(ev, entries),
              onPointerUp: (_) => _handleRightProblemPointerEnd(),
              onPointerCancel: (_) => _handleRightProblemPointerEnd(),
              onPointerSignal: _handleRightPageScrollSignal,
              child: SizedBox(
                width: double.infinity,
                height: totalH,
              ),
            ),
            IgnorePointer(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: rowWidgets,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRightMidPagePanel() {
    final resolved = _resolveActiveMid();
    if (resolved == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            '중단원을 선택하세요.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: kDlgTextSub,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ),
      );
    }
    final big = resolved.key;
    final mid = resolved.value;
    if (_rangePickerMode == 'type') {
      return _buildRightTypeProblemPanel(big, mid);
    }
    final totalH = _rightFlatContentHeight(mid);
    if (totalH <= 0) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            '이 중단원에 표시할 페이지가 없습니다.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: kDlgTextSub,
              fontWeight: FontWeight.w600,
              fontSize: 12.5,
            ),
          ),
        ),
      );
    }

    final rowWidgets = <Widget>[];
    _RightFlatEntry? prev;
    for (final e in _rightFlatEntries(mid)) {
      if (e.isHeader) {
        final small = mid.smalls[e.smallIndex];
        final blocked = small.draftBlocked;
        final expandKey = _smallExpandKey(big, mid, small);
        final prefix = _smallTitlePrefix(big, mid, small);
        rowWidgets.add(
          SizedBox(
            key: _headerKeyForSmallExpand(expandKey),
            height: _kMidRightSmallHeaderHeight,
            child: Container(
              width: double.infinity,
              color: const Color(0x1F0F1518),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.centerLeft,
              child: LatexTextRenderer(
                '$prefix ${small.name}',
                style: TextStyle(
                  color: blocked ? const Color(0xFF6D7777) : kDlgTextSub,
                  fontWeight: FontWeight.w600,
                  fontSize: 12.4,
                  height: 1.15,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        );
      } else {
        final small = mid.smalls[e.smallIndex];
        final blocked = small.draftBlocked;
        final pages = _smallPages(small).toList()..sort();
        final pi = e.pageSortedIndex!;
        if (pi >= pages.length) {
          prev = e;
          continue;
        }
        final pageNum = pages[pi];
        final pageChecked = _isRightPageChecked(small, pageNum);
        final afterHeader = prev?.isHeader == true;
        rowWidgets.add(
          SizedBox(
            height: _kSmallPageListRowStride,
            child: Container(
              decoration: BoxDecoration(
                border: Border(
                  top: afterHeader
                      ? BorderSide.none
                      : const BorderSide(color: kDlgBorder, width: 1),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.centerLeft,
              child: Row(
                children: [
                  Icon(
                    pageChecked
                        ? Icons.check_box_rounded
                        : Icons.check_box_outline_blank_rounded,
                    size: 22,
                    color: blocked
                        ? const Color(0xFF6D7777)
                        : (pageChecked ? kDlgAccent : kDlgBorder),
                  ),
                  const SizedBox(width: 15),
                  Expanded(
                    child: Text(
                      'P.$pageNum',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: kDlgText,
                        fontWeight: FontWeight.w600,
                        fontSize: 13.2,
                      ),
                    ),
                  ),
                  _buildRightPageRowMeta(
                    small: small,
                    pageNum: pageNum,
                    blocked: blocked,
                  ),
                ],
              ),
            ),
          ),
        );
      }
      prev = e;
    }

    return Scrollbar(
      controller: _rangeRightScrollController,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _rangeRightScrollController,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (ev) => _handleRightPagePointerDown(ev, big, mid),
              onPointerMove: (ev) => _handleRightPagePointerMove(ev, big, mid),
              onPointerUp: (ev) => _handleRightPagePointerUp(ev, big, mid),
              onPointerCancel: (_) => _handleRightPagePointerCancel(),
              onPointerSignal: _handleRightPageScrollSignal,
              child: SizedBox(
                width: double.infinity,
                height: totalH,
              ),
            ),
            IgnorePointer(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: rowWidgets,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLeftUnitTreeColumn() {
    return Theme(
      data: Theme.of(context).copyWith(
        dividerColor: Colors.transparent,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
      ),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _handleLeftTreePointerDown,
        onPointerMove: _handleLeftTreePointerMove,
        onPointerUp: _handleLeftTreePointerUp,
        onPointerCancel: _handleLeftTreePointerCancel,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final big in _units)
              ExpansionTile(
                key: ValueKey('quickadd_big_${big.orderIndex}'),
                initiallyExpanded: true,
                expansionAnimationStyle: _fastTreeExpansionStyle,
                tilePadding:
                    const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                childrenPadding: const EdgeInsets.fromLTRB(
                  _kTreeMidIndentFromBig,
                  0,
                  10,
                  8,
                ),
                maintainState: true,
                iconColor: kDlgTextSub,
                collapsedIconColor: kDlgTextSub,
                title: Row(
                  children: [
                    _buildTreeCheckbox(
                      value: big.selected,
                      onChanged: _hasEditableSmallInBig(big)
                          ? (v) => _toggleBig(big, v ?? false)
                          : null,
                      disabled: !_hasEditableSmallInBig(big),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: LatexTextRenderer(
                        big.name,
                        style: const TextStyle(
                          color: kDlgText,
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5,
                        ),
                      ),
                    ),
                  ],
                ),
                children: [
                  for (final mid in big.middles) _buildLeftMidBlock(big, mid),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildLeftMidBlock(
    _BigUnitSelectionNode big,
    _MidUnitSelectionNode mid,
  ) {
    final midKey = _midExpandKey(big, mid);
    final active = _activeMidKey == midKey;
    final smallsExpanded = _expandedLeftMidSmallsKey == midKey;
    final hasSmalls = mid.smalls.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: _buildTreeCheckbox(
                  value: mid.selected,
                  onChanged: _hasEditableSmallInMid(mid)
                      ? (v) => _toggleMid(big, mid, v ?? false)
                      : null,
                  disabled: !_hasEditableSmallInMid(mid),
                ),
              ),
              Expanded(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => _onLeftMidRowTapped(big, mid),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          if (hasSmalls) ...[
                            AnimatedRotation(
                              turns: smallsExpanded ? 0.25 : 0,
                              duration: _kTreeSmallsExpandDuration,
                              curve: _kTreeSmallsExpandCurve,
                              child: Icon(
                                Icons.chevron_right,
                                size: 22,
                                color: kDlgTextSub,
                              ),
                            ),
                            const SizedBox(width: 6),
                          ],
                          Expanded(
                            child: LatexTextRenderer(
                              mid.name,
                              style: TextStyle(
                                color: active ? kDlgAccent : kDlgText,
                                fontWeight:
                                    active ? FontWeight.w700 : FontWeight.w600,
                                fontSize: 13,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          AnimatedSize(
            duration: _kTreeSmallsExpandDuration,
            curve: _kTreeSmallsExpandCurve,
            alignment: Alignment.topLeft,
            clipBehavior: Clip.hardEdge,
            child: smallsExpanded && hasSmalls
                ? Column(
                    key: ValueKey<String>('left_smalls_$midKey'),
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 4),
                      Padding(
                        padding: const EdgeInsets.only(
                          left: _kTreeMidIndentFromBig,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final small in mid.smalls)
                              _buildLeftSmallRow(big, mid, small),
                          ],
                        ),
                      ),
                    ],
                  )
                : const SizedBox(
                    width: double.infinity,
                    height: 0,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildLeftSmallRow(
    _BigUnitSelectionNode big,
    _MidUnitSelectionNode mid,
    _SmallUnitSelectionNode small,
  ) {
    final expandKey = _smallExpandKey(big, mid, small);
    final page = _pageTextForSmall(small);
    final titleText = page.isEmpty ? small.name : '${small.name} (p.$page)';
    final blocked = small.draftBlocked;
    final typeFocused =
        _rangePickerMode == 'type' && _activeTypeSmallKey == expandKey;
    final highlight =
        typeFocused || small.selected || small.selectedPages.isNotEmpty;
    final doneText = _smallRowStatusSuffix(small);
    return Padding(
      key: _leftSmallRowKeys.putIfAbsent(expandKey, GlobalKey.new),
      padding: const EdgeInsets.only(bottom: 6),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        decoration: BoxDecoration(
          color: blocked
              ? const Color(0x1F0F1518)
              : (highlight ? const Color(0x1A33A373) : Colors.transparent),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: blocked
                ? const Color(0xFF2E3C3F)
                : (highlight
                    ? kDlgAccent.withOpacity(0.9)
                    : kDlgBorder.withOpacity(0.8)),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 5),
              child: _buildTreeCheckbox(
                value: small.selected,
                onChanged: blocked
                    ? null
                    : (v) => _toggleSmallWhole(big, mid, small, v ?? false),
                disabled: blocked,
              ),
            ),
            const SizedBox(width: _kLeftSmallCheckboxToTitleGap),
            Expanded(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: blocked
                      ? null
                      : () => _onLeftSmallRowTapped(big, mid, small),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 10,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: LatexTextRenderer(
                            titleText,
                            style: TextStyle(
                              color: blocked
                                  ? const Color(0xFF6D7777)
                                  : kDlgTextSub,
                              fontWeight: FontWeight.w600,
                              fontSize: 12.5,
                              height: 1.2,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            softWrap: true,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          doneText,
                          style: TextStyle(
                            color: blocked
                                ? const Color(0xFF6D7777)
                                : (small.completedCount > 0
                                    ? kDlgAccent
                                    : kDlgTextSub),
                            fontWeight: FontWeight.w700,
                            fontSize: blocked ? 11.5 : 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetadataTree(_LinkedTextbook? selectedBook) {
    if (selectedBook == null) {
      return _buildNoticeCard('연결된 교재를 선택하세요.');
    }
    if (_loadingMetadata) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 22),
        decoration: BoxDecoration(
          color: kDlgPanelBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kDlgBorder),
        ),
        child: const Center(child: YggLoadingIndicator(size: 18)),
      );
    }
    if (_units.isEmpty) {
      return _buildNoticeCard('선택한 교재의 메타데이터가 없습니다.');
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 44,
          child: Scrollbar(
            controller: _leftTreeScrollController,
            child: SingleChildScrollView(
              controller: _leftTreeScrollController,
              physics: _leftSmallDragPointerDown && _leftSmallDragMovedPastSlop
                  ? const NeverScrollableScrollPhysics()
                  : null,
              child: _buildLeftUnitTreeColumn(),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: 21,
          child: Container(
            decoration: BoxDecoration(
              color: kDlgPanelBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: kDlgBorder),
            ),
            clipBehavior: Clip.antiAlias,
            child: _buildRightMidPagePanel(),
          ),
        ),
      ],
    );
  }

  Future<void> _submitWonriTimedTestV0({
    required _LinkedTextbook book,
    required String action,
  }) async {
    if (!_testTimeLimitEnabled) {
      _showDialogSnackBar('시간 제한을 선택하세요.');
      return;
    }
    final timeLimitMinutes = _parsePositiveIntText(_timeLimitMinutes.text);
    if (timeLimitMinutes == null) {
      _showDialogSnackBar('제한시간을 양의 분 단위로 입력하세요.');
      return;
    }
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      final result = await _loadWonriTimedTestEligibility(book);
      if (!mounted || _selectedLinkedBook?.key != book.key) return;
      setState(() {
        _timedTestEligibleCount = result.eligible.length;
        _timedTestExcludedCount = result.excluded;
        _timedTestEligibilityLoading = false;
      });
      if (result.eligible.isEmpty) {
        _showDialogSnackBar(
          result.excluded > 0
              ? '자동채점 가능한 문항이 없습니다. 자가채점 문항 ${result.excluded}개를 제외했습니다.'
              : '선택된 문항이 없습니다.',
        );
        return;
      }

      final base = _buildProblemSubtaskDraftItem(
        book,
        result.eligible,
        _resolveSmallNodeForRegions(
          result.eligible,
          _smallNodeByUnitKey(),
        ),
        draftKey: 'wonri_timed_v0',
      );
      final seed = wonriTimedTestStableSeed(result.seedMaterial);
      final seedLabel = seed.toRadixString(16).padLeft(8, '0');
      final mappings = base.unitMappings.map((raw) {
        final mapping = Map<String, dynamic>.from(raw);
        final crops = result.eligible.map((region) {
          final crop = region.toMappingJson();
          crop['gradingMode'] = 'auto';
          crop['recommenderCategory'] = normalizeWonriTimedTestCategory(
                _timedTestCategoryLabel(region),
              ) ??
              'other';
          crop['recommenderKey'] = wonriTimedTestRecommenderKey;
          crop['recommenderVersion'] = wonriTimedTestRecommenderVersion;
          crop['recommenderSeed'] = seedLabel;
          crop['recommenderWeights'] =
              Map<String, double>.from(wonriTimedTestCategoryWeights);
          return crop;
        }).toList(growable: false);
        mapping
          ..['sourceScope'] = wonriTimedTestRecommenderKey
          ..['problemCount'] = crops.length
          ..['problemNumbers'] =
              result.eligible.map((region) => region.problemNumber).toList()
          ..['problemCrops'] = crops
          ..['recommender_key'] = wonriTimedTestRecommenderKey
          ..['recommender_version'] = wonriTimedTestRecommenderVersion
          ..['recommender_seed'] = seedLabel
          ..['recommender_weights'] =
              Map<String, double>.from(wonriTimedTestCategoryWeights)
          ..['recommender'] = <String, dynamic>{
            'key': wonriTimedTestRecommenderKey,
            'version': wonriTimedTestRecommenderVersion,
            'seed': seedLabel,
            'weights': Map<String, double>.from(
              wonriTimedTestCategoryWeights,
            ),
            'eligibleCount': result.eligible.length,
            'excludedSelfGradeCount': result.excluded,
          };
        return mapping;
      }).toList(growable: false);
      const title = '시간 제한 테스트';
      final content =
          '${_bookMetaText(book)}\n자동채점 ${result.eligible.length}문항 · 자가채점 제외 ${result.excluded}문항';
      final item = base.copyWith(
        title: title,
        count: '${result.eligible.length}',
        content: content,
        body: _composeBodyValues(
          page: base.page,
          count: '${result.eligible.length}',
          content: content,
          timeLimitMinutes: timeLimitMinutes,
        ),
        unitMappings: mappings,
        splitParts: 1,
        timeLimitMinutes: timeLimitMinutes,
        testMode: true,
        testOriginFlowId: _currentTestOriginFlowId(),
      );
      final groupTitle =
          _groupTitle.text.trim().isEmpty ? title : _groupTitle.text.trim();
      Navigator.pop(context, {
        'studentId': widget.studentId,
        'groupMode': true,
        if (_isChildAddMode) 'childAddMode': true,
        'groupTitle': groupTitle,
        'flowId': _flowId,
        'action': action,
        if (widget.requirePlanDestination)
          'planDestination': _selectedPlanDestination,
        'items': <Map<String, dynamic>>[item.toJson()],
      });
    } catch (_) {
      if (mounted) {
        _showDialogSnackBar('자동채점 가능 문항을 확인하지 못했습니다. 다시 시도해주세요.');
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _submit({String action = 'add'}) async {
    final resolvedAction = _isChildAddMode ? 'add' : action;
    if (_flowId.isEmpty) {
      _showDialogSnackBar('플로우를 선택하세요.');
      return;
    }

    final selectedBookForTest = _selectedLinkedBook;
    if (selectedBookForTest != null && _isWonriTimedTestV0Active()) {
      await _submitWonriTimedTestV0(
        book: selectedBookForTest,
        action: resolvedAction,
      );
      return;
    }
    final groupTimeLimitMinutes =
        _isCurrentHomeworkTypeTest() && _testTimeLimitEnabled
            ? _parsePositiveIntText(_timeLimitMinutes.text)
            : null;
    if (_isCurrentHomeworkTypeTest() &&
        _testTimeLimitEnabled &&
        groupTimeLimitMinutes == null) {
      _showDialogSnackBar('제한시간을 양의 분 단위로 입력하세요.');
      return;
    }

    if (_draftGroupItems.isNotEmpty) {
      final groupTitle =
          _groupTitle.text.trim().isEmpty ? '그룹 과제' : _groupTitle.text.trim();
      final normalizedDraftItems = _draftGroupItems.map((original) {
        final item = original.testMode
            ? original.copyWith(timeLimitMinutes: groupTimeLimitMinutes)
            : original;
        final compactPage = _normalizePageTextCompact(item.page);
        if (compactPage == item.page && !item.testMode) return item;
        return item.copyWith(
          page: compactPage,
          body: _composeBodyValues(
            page: compactPage,
            count: item.count,
            content: item.content,
            timeLimitMinutes: item.timeLimitMinutes,
          ),
        );
      }).toList(growable: false);
      Navigator.pop(context, {
        'studentId': widget.studentId,
        'groupMode': true,
        if (_isChildAddMode) 'childAddMode': true,
        'groupTitle': groupTitle,
        'flowId': _flowId,
        'action': resolvedAction,
        if (widget.requirePlanDestination)
          'planDestination': _selectedPlanDestination,
        'items':
            normalizedDraftItems.map((e) => e.toJson()).toList(growable: false),
      });
      return;
    }

    final selectedBook = _selectedLinkedBook;
    if (selectedBook == null) {
      _showDialogSnackBar(
        _naesinStandaloneMode ? '기출 셀을 선택하세요.' : '하위 과제를 1개 이상 추가하세요.',
      );
      return;
    }

    if (!_autoSubtaskMode) {
      _showDialogSnackBar('하위 과제를 1개 이상 추가하세요.');
      return;
    }

    if (_manualPageMode) {
      final linkedType = _linkedHomeworkType;
      final page = _page.text.trim();
      final count = _count.text.trim();
      final testMode = _isCurrentHomeworkTypeTest();
      final timeLimitMinutes =
          testMode ? _parsePositiveIntText(_timeLimitMinutes.text) : null;
      var content = _content.text.trim();
      final inputTitle = _title.text.trim();
      if (page.isEmpty && content.isEmpty) {
        _showDialogSnackBar('페이지 또는 내용을 입력하세요.');
        return;
      }
      final title = inputTitle.isEmpty ? '교재 과제' : inputTitle;
      final bookMeta = _bookMetaText(selectedBook);
      content = content.isEmpty ? bookMeta : '$bookMeta\n$content';
      final recommendedMinutes = _estimateRecommendedMinutesForCount(
        selectedBook,
        count: _parsePositiveIntText(count),
        pageText: page,
      );
      Navigator.pop(context, {
        'studentId': widget.studentId,
        'flowId': _flowId,
        'action': resolvedAction,
        if (widget.requirePlanDestination)
          'planDestination': _selectedPlanDestination,
        'type': linkedType,
        'title': title,
        'page': page,
        'count': count,
        'memo': _memo.text.trim(),
        'content': content,
        'body': _composeBodyValues(
          page: page,
          count: count,
          content: content,
          timeLimitMinutes: timeLimitMinutes,
        ),
        'color': _colorForType(linkedType),
        if (timeLimitMinutes != null) 'timeLimitMinutes': timeLimitMinutes,
        if (recommendedMinutes != null) ...{
          'recommendedMinutes': recommendedMinutes,
          'recommendedMinutesAuto': recommendedMinutes,
        },
        if (testMode) 'testMode': true,
        if (testMode && (_currentTestOriginFlowId() ?? '').isNotEmpty)
          'testOriginFlowId': _currentTestOriginFlowId(),
        'bookId': selectedBook.bookId,
        'gradeLabel': selectedBook.gradeLabel,
        'sourceUnitLevel': 'manual',
        'sourceUnitPath': null,
        'unitMappings': const <Map<String, dynamic>>[],
        'splitParts': _defaultSplitParts,
      });
      return;
    }

    // 범위 선택은 소단원 단위로 자동 분해한다.
    // 하위과제가 2개 이상이면 그룹 과제로, 1개면 기존 단일 과제로 제출한다.
    final autoSubtasks = _buildAutoSubtaskDraftItems(selectedBook);
    if (autoSubtasks.isEmpty) {
      _showDialogSnackBar(
        _rangePickerMode == 'type'
            ? '문항을 1개 이상 선택하세요.'
            : '대/중/소단원을 1개 이상 선택하세요.',
      );
      return;
    }
    if (autoSubtasks.length > 1) {
      final fallbackGroupTitle = () {
        if (_groupTitleManuallyEdited) {
          final staged = _groupTitle.text.trim();
          if (staged.isNotEmpty) return staged;
        }
        final resolved = _resolveGroupTitleFromDraftItems(autoSubtasks);
        if (resolved.trim().isNotEmpty) return resolved;
        final staged = _groupTitle.text.trim();
        if (staged.isNotEmpty) return staged;
        return '그룹 과제';
      }();
      final groupItems = autoSubtasks
          .map((e) => e.copyWith(splitParts: 1))
          .toList(growable: false);
      Navigator.pop(context, {
        'studentId': widget.studentId,
        'groupMode': true,
        if (_isChildAddMode) 'childAddMode': true,
        'groupTitle': fallbackGroupTitle,
        'flowId': _flowId,
        'action': resolvedAction,
        if (widget.requirePlanDestination)
          'planDestination': _selectedPlanDestination,
        'items': groupItems.map((e) => e.toJson()).toList(growable: false),
      });
      return;
    }

    final mergedTask = _buildMergedRangeTask(selectedBook);
    if (mergedTask == null || mergedTask.unitMappings.isEmpty) {
      _showDialogSnackBar('대/중/소단원을 1개 이상 선택하세요.');
      return;
    }

    final selectedUnits = _sortedSelectedSmallUnits(_selectedSmallUnits());
    final titleRaw = _rangeTitle.text.trim();
    final contentRaw = _rangeContent.text.trim();
    final linkedType = _linkedHomeworkType;
    final testMode = _isCurrentHomeworkTypeTest();
    final timeLimitMinutes =
        testMode ? _parsePositiveIntText(_timeLimitMinutes.text) : null;
    var title = titleRaw.isEmpty ? mergedTask.title : titleRaw;
    var content = contentRaw;
    if (selectedUnits.length > 1 && mergedTask.allowAiSummaryTitle) {
      final aiSummary =
          await _createAiSummaryLabel(selectedBook, selectedUnits);
      if (!mounted) return;
      if (aiSummary.isNotEmpty) {
        final rangeText = _rangeScopeTextFromSelected(selectedUnits);
        if (titleRaw.isEmpty) {
          title = aiSummary;
        }
        if (contentRaw.isEmpty || contentRaw == mergedTask.content) {
          content =
              '${_bookMetaText(selectedBook)}\n범위: $rangeText\n요약: $aiSummary';
        }
      }
    }
    if (title.trim().isEmpty) {
      _showDialogSnackBar('과제명을 입력하세요.');
      return;
    }

    final int? mergedRecommendedMinutes = () {
      if (_rangePickerMode == 'type') {
        final regions = _selectedProblemRegions();
        if (regions.isNotEmpty) {
          return _estimateRecommendedMinutesForRegions(selectedBook, regions);
        }
      }
      return _estimateRecommendedMinutesForCount(
        selectedBook,
        count: _parsePositiveIntText(mergedTask.count),
        pageText: mergedTask.page,
      );
    }();

    Navigator.pop(context, {
      'studentId': widget.studentId,
      'flowId': _flowId,
      'action': resolvedAction,
      if (widget.requirePlanDestination)
        'planDestination': _selectedPlanDestination,
      'type': linkedType,
      'title': title,
      'page': mergedTask.page,
      'count': mergedTask.count,
      'memo': _memo.text.trim(),
      'content': content,
      'body': _composeBodyValues(
        page: mergedTask.page,
        count: mergedTask.count,
        content: content,
        timeLimitMinutes: timeLimitMinutes,
      ),
      'color': _colorForType(linkedType),
      if (timeLimitMinutes != null) 'timeLimitMinutes': timeLimitMinutes,
      if (mergedRecommendedMinutes != null) ...{
        'recommendedMinutes': mergedRecommendedMinutes,
        'recommendedMinutesAuto': mergedRecommendedMinutes,
      },
      if (testMode) 'testMode': true,
      if (testMode && (_currentTestOriginFlowId() ?? '').isNotEmpty)
        'testOriginFlowId': _currentTestOriginFlowId(),
      'bookId': selectedBook.bookId,
      'gradeLabel': selectedBook.gradeLabel,
      'sourceUnitLevel': mergedTask.sourceUnitLevel,
      'sourceUnitPath': mergedTask.sourceUnitPath,
      'unitMappings': List<Map<String, dynamic>>.from(
        mergedTask.unitMappings.map((e) => Map<String, dynamic>.from(e)),
      ),
      'splitParts': _defaultSplitParts,
    });
  }

  Widget _buildNaesinStatusCell({
    required String school,
    required int year,
    required bool highlightedSchool,
    required String cellLabel,
    required List<_NaesinLinkedCellOption> options,
    double cellSize = _kNaesinGridCellSize,
  }) {
    final linkedActive = options.isNotEmpty;
    final cellStatus = options.isNotEmpty ? options.first.status : null;
    final displayCellLabel =
        options.isNotEmpty ? options.first.cellLabel.trim() : cellLabel.trim();
    final hasCellLabel = displayCellLabel.isNotEmpty;
    final hasIssued = cellStatus?.issuedAt != null;
    final isCompleted = cellStatus?.isCompleted == true;
    final isEnded = (cellStatus?.isEnded == true) || isCompleted;
    final scoreLabel = (cellStatus?.scoreLabel ?? '').trim();
    final hasScore = scoreLabel.isNotEmpty;
    final displayText = () {
      if (isCompleted) return hasScore ? scoreLabel : '완료';
      if (isEnded) return hasScore ? scoreLabel : '종료';
      if (hasIssued) return _formatNaesinIssuedDate(cellStatus!.issuedAt!);
      return '';
    }();
    final borderColor = isCompleted
        ? const Color(0xFF4DBD7A)
        : (linkedActive
            ? _kNaesinLinkedActiveCellColor
            : (highlightedSchool ? kDlgAccent.withOpacity(0.7) : kDlgBorder));
    final fillColor = isCompleted
        ? const Color(0xFF1F4B36)
        : (linkedActive
            ? _kNaesinLinkedActiveCellColor
            : (highlightedSchool
                ? const Color(0x1A33A373)
                : const Color(0xFF151C21)));
    final tooltipLines = <String>[
      '$school · $year',
      if (hasCellLabel) displayCellLabel,
    ];
    if (cellStatus?.firstIssuedAt != null) {
      tooltipLines.add(
          '처음 내준 시각 ${_formatNaesinIssuedDateTime(cellStatus!.firstIssuedAt!)}');
    }
    if (cellStatus != null) {
      tooltipLines
          .add('걸린 시간 ${_formatNaesinElapsedDuration(cellStatus.elapsedMs)}');
    }
    if (isCompleted) {
      tooltipLines.add('상태 완료');
    } else if (isEnded) {
      tooltipLines.add('상태 종료');
    }
    if (hasScore) {
      tooltipLines.add('점수 $scoreLabel');
    }
    final singleTap = options.isNotEmpty
        ? () => _onNaesinStatusCellTapped(
              school: school,
              year: year,
              linkKey: options.first.linkKey,
            )
        : null;
    final child = hasCellLabel || displayText.isNotEmpty
        ? Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (hasCellLabel)
                    Text(
                      displayCellLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: kDlgText,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        height: 1.05,
                      ),
                    ),
                  if (hasCellLabel && displayText.isNotEmpty)
                    const SizedBox(height: 3),
                  if (displayText.isNotEmpty)
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        displayText,
                        maxLines: 1,
                        style: TextStyle(
                          color: isCompleted
                              ? const Color(0xFFE4F8EC)
                              : (isEnded ? kDlgText : kDlgTextSub),
                          fontWeight:
                              hasScore ? FontWeight.w800 : FontWeight.w700,
                          fontSize: hasScore ? 12 : 10.8,
                          letterSpacing: hasScore ? 0.2 : 0.1,
                          height: 1.0,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          )
        : null;
    return Tooltip(
      message: tooltipLines.join('\n'),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: singleTap,
          child: Container(
            width: cellSize,
            height: cellSize,
            decoration: BoxDecoration(
              color: fillColor,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: borderColor),
            ),
            child: child,
          ),
        ),
      ),
    );
  }

  Widget _buildNaesinYearSchoolRow(
    int year, {
    required double cellSize,
    required double cellGap,
    required double rowGap,
    required bool isLast,
  }) {
    final studentSchool = _naesinStudentSchool;
    final schools = _naesinSchools;
    final optionsBySchool = <String, List<_NaesinLinkedCellOption>>{
      for (final school in schools)
        school: _naesinLinkedOptionsForSchoolYear(school: school, year: year),
    };
    final slotCount = math.max(
      1,
      optionsBySchool.values.fold<int>(
        0,
        (maxCount, options) => math.max(maxCount, options.length),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var slot = 0; slot < slotCount; slot++)
            Padding(
              padding: EdgeInsets.only(
                bottom: slot == slotCount - 1 && isLast ? 0 : rowGap,
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: _kNaesinGridYearLabelWidth,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: slot == 0
                          ? Text(
                              '$year',
                              textAlign: TextAlign.right,
                              style: const TextStyle(
                                color: kDlgTextSub,
                                fontSize: 13.2,
                                fontWeight: FontWeight.w700,
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                  const SizedBox(width: _kNaesinGridLabelToCellsGap),
                  for (var i = 0; i < schools.length; i++) ...[
                    (() {
                      final school = schools[i];
                      final highlightedSchool =
                          studentSchool.isNotEmpty && studentSchool == school;
                      final options = optionsBySchool[school] ??
                          const <_NaesinLinkedCellOption>[];
                      if (slot >= options.length && slot > 0) {
                        return SizedBox(width: cellSize, height: cellSize);
                      }
                      final option =
                          slot < options.length ? options[slot] : null;
                      return _buildNaesinStatusCell(
                        school: school,
                        year: year,
                        highlightedSchool: highlightedSchool,
                        cellLabel: option?.cellLabel ?? '',
                        options: option == null
                            ? const <_NaesinLinkedCellOption>[]
                            : <_NaesinLinkedCellOption>[option],
                        cellSize: cellSize,
                      );
                    })(),
                    if (i < schools.length - 1) SizedBox(width: cellGap),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildNaesinSchoolYearGrid() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final schools = _naesinSchools;
        final columnCount = schools.length;
        const headerTop = 10.0;
        const headerBottom = 8.0;
        const headerRowHeight = 18.0;
        const dividerHeight = 1.0;
        const bodyTop = 8.0;
        final rowCount = _naesinGridVisualRowCount();
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : double.infinity;
        final availableHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : double.infinity;
        final gridWidth = availableWidth.isFinite
            ? math.max(
                0.0,
                availableWidth -
                    12 -
                    _kNaesinGridYearLabelWidth -
                    _kNaesinGridLabelToCellsGap,
              )
            : double.infinity;
        final bodyHeight = availableHeight.isFinite
            ? math.max(
                0.0,
                availableHeight -
                    headerTop -
                    headerRowHeight -
                    headerBottom -
                    dividerHeight -
                    bodyTop,
              )
            : double.infinity;

        final widthCellSize = gridWidth.isFinite && columnCount > 0
            ? ((gridWidth - (columnCount - 1) * _kNaesinGridMinCellGap) /
                    columnCount)
                .clamp(_kNaesinGridMinCellSize, _kNaesinGridCellSize)
                .toDouble()
            : _kNaesinGridCellSize;
        final heightCellSize = bodyHeight.isFinite
            ? ((bodyHeight - (rowCount - 1) * _kNaesinGridMinRowGap) / rowCount)
                .clamp(_kNaesinGridMinCellSize, _kNaesinGridCellSize)
                .toDouble()
            : _kNaesinGridCellSize;
        final cellSize = math.min(widthCellSize, heightCellSize);
        final cellGap = gridWidth.isFinite && columnCount > 1
            ? math
                .max(
                  0.0,
                  (gridWidth - columnCount * cellSize) / (columnCount - 1),
                )
                .clamp(0.0, _kNaesinGridCellGap)
                .toDouble()
            : _kNaesinGridCellGap;
        final rowGap = bodyHeight.isFinite && rowCount > 1
            ? math
                .max(
                  0.0,
                  (bodyHeight - rowCount * cellSize) / (rowCount - 1),
                )
                .clamp(0.0, _kNaesinGridCellGap)
                .toDouble()
            : _kNaesinGridCellGap;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(6, headerTop, 6, headerBottom),
              child: Row(
                children: [
                  const SizedBox(
                    width: _kNaesinGridYearLabelWidth,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        '년도',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: kDlgTextSub,
                          fontWeight: FontWeight.w700,
                          fontSize: 12.2,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: _kNaesinGridLabelToCellsGap),
                  for (var i = 0; i < schools.length; i++) ...[
                    SizedBox(
                      width: cellSize,
                      child: Center(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            schools[i],
                            maxLines: 1,
                            style: TextStyle(
                              color: _naesinStudentSchool.isNotEmpty &&
                                      _naesinStudentSchool == schools[i]
                                  ? kDlgAccent
                                  : kDlgTextSub,
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (i < schools.length - 1) SizedBox(width: cellGap),
                  ],
                ],
              ),
            ),
            const Divider(height: 1, thickness: 1, color: kDlgBorder),
            if (_loadingNaesinLinkedCellKeys)
              const LinearProgressIndicator(
                minHeight: 1.2,
                backgroundColor: Colors.transparent,
                valueColor: AlwaysStoppedAnimation<Color>(kDlgAccent),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: bodyTop),
                child: Column(
                  children: [
                    for (var i = 0; i < _kNaesinYears.length; i++)
                      _buildNaesinYearSchoolRow(
                        _kNaesinYears[i],
                        cellSize: cellSize,
                        cellGap: cellGap,
                        rowGap: rowGap,
                        isLast: i == _kNaesinYears.length - 1,
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildNaesinRangePanel() {
    if (_naesinGradeKey.isEmpty ||
        _naesinCourseKey.isEmpty ||
        _naesinExamTerm.isEmpty) {
      _initNaesinFilterDefaults();
    }
    final gradeOptions = _naesinAllGradeOptions;
    final safeGradeKey = gradeOptions.any((e) => e.key == _naesinGradeKey)
        ? _naesinGradeKey
        : gradeOptions.first.key;
    if (safeGradeKey != _naesinGradeKey) {
      _naesinGradeKey = safeGradeKey;
    }
    _syncNaesinCourseWithGrade();
    final courseOptions = _naesinCourseOptionsForGrade(_naesinGradeKey);
    final safeCourseKey = courseOptions.any((e) => e.key == _naesinCourseKey)
        ? _naesinCourseKey
        : courseOptions.first.key;
    if (safeCourseKey != _naesinCourseKey) {
      _naesinCourseKey = safeCourseKey;
    }
    final safeExamTerm = _kNaesinExamTerms.contains(_naesinExamTerm)
        ? _naesinExamTerm
        : _kNaesinExamTerms.first;
    if (safeExamTerm != _naesinExamTerm) {
      _naesinExamTerm = safeExamTerm;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const YggDialogSectionHeader(
          icon: Icons.account_tree_outlined,
          title: '범위 선택',
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _naesinGradeKey,
                items: [
                  for (final e in gradeOptions)
                    DropdownMenuItem<String>(
                        value: e.key, child: Text(e.label)),
                ],
                onChanged: (v) {
                  final next = (v ?? '').trim();
                  if (next.isEmpty || next == _naesinGradeKey) return;
                  setState(() {
                    _naesinGradeKey = next;
                    _syncNaesinCourseWithGrade();
                  });
                },
                decoration: _inputDecoration('학년'),
                dropdownColor: kDlgPanelBg,
                style: const TextStyle(
                    color: kDlgText, fontWeight: FontWeight.w600),
                iconEnabledColor: kDlgTextSub,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _naesinCourseKey,
                items: [
                  for (final e in courseOptions)
                    DropdownMenuItem<String>(
                        value: e.key, child: Text(e.label)),
                ],
                onChanged: (v) {
                  final next = (v ?? '').trim();
                  if (next.isEmpty || next == _naesinCourseKey) return;
                  setState(() => _naesinCourseKey = next);
                },
                decoration: _inputDecoration('과정'),
                dropdownColor: kDlgPanelBg,
                style: const TextStyle(
                    color: kDlgText, fontWeight: FontWeight.w600),
                iconEnabledColor: kDlgTextSub,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _naesinExamTerm,
                items: [
                  for (final term in _kNaesinExamTerms)
                    DropdownMenuItem<String>(value: term, child: Text(term)),
                ],
                onChanged: (v) {
                  final next = (v ?? '').trim();
                  if (next.isEmpty || next == _naesinExamTerm) return;
                  setState(() => _naesinExamTerm = next);
                },
                decoration: _inputDecoration('시험 구분'),
                dropdownColor: kDlgPanelBg,
                style: const TextStyle(
                    color: kDlgText, fontWeight: FontWeight.w600),
                iconEnabledColor: kDlgTextSub,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(child: _buildNaesinSchoolYearGrid()),
      ],
    );
  }

  Widget _buildNaesinStandalonePanel() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kDlgPanelBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kDlgBorder),
      ),
      child: _buildNaesinRangePanel(),
    );
  }

  Map<String, List<_LinkedTextbook>> _groupLinkedTextbooks(
    Iterable<_LinkedTextbook> links,
  ) {
    final groups = <String, List<_LinkedTextbook>>{};
    for (final link in links) {
      groups.putIfAbsent(link.gradeLabel, () => <_LinkedTextbook>[]).add(link);
    }
    return groups;
  }

  Future<bool> _confirmUnbindTextbook(_LinkedTextbook link) async {
    final bookLabel =
        link.bookName.trim().isEmpty ? '선택한 교재' : link.bookName.trim();
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: kDlgBg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: const Text(
            '교재 바인딩 해제',
            style: TextStyle(
              color: kDlgText,
              fontWeight: FontWeight.w900,
            ),
          ),
          content: Text(
            '「$bookLabel」 바인딩을 해제하면 이 학생의 해당 교재 풀이·채점·과제·학습 기록이 '
            '모두 삭제되며 복구할 수 없습니다.\n\n'
            '원본 교재(학원 공용 메타데이터·문항)에는 영향을 주지 않습니다.',
            style: const TextStyle(
              color: kDlgTextSub,
              fontSize: 14,
              height: 1.45,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFC62828),
              ),
              child: const Text('바인딩 해제'),
            ),
          ],
        );
      },
    );
    return result == true;
  }

  Future<bool> _unbindLinkedTextbook(_LinkedTextbook link) async {
    final confirmed = await _confirmUnbindTextbook(link);
    if (!confirmed || !mounted) return false;
    try {
      await DataManager.instance.unbindStudentTextbook(
        studentId: widget.studentId,
        flowId: link.flowId,
        bookId: link.bookId,
        gradeLabel: link.gradeLabel,
      );
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_ackPrefsKeyForLinkedBook(link));
      } catch (_) {}

      final bookIdentity = _bookIdentity(link);
      final remaining = _allLinkedTextbooks
          .where((row) => row.key != link.key)
          .toList(growable: false);
      final nextOverrides = Map<String, bool>.from(_textbookActiveOverrides)
        ..removeWhere(
          (key, _) =>
              key == link.key ||
              key.endsWith('|${link.bookId}|${link.gradeLabel}'),
        );

      if (!mounted) return true;
      setState(() {
        _allLinkedTextbooks = remaining;
        _textbookActiveOverrides = nextOverrides;
        if (_selectedLinkedBookKey == link.key ||
            (bookIdentity != null &&
                _bookIdentity(_selectedLinkedBook) == bookIdentity)) {
          _selectedLinkedBookKey = null;
          _units = const <_BigUnitSelectionNode>[];
          _manualPageMode = false;
        }
        if (bookIdentity != null) {
          _draftGroupItems.removeWhere(
            (item) => '${item.bookId}|${item.gradeLabel}' == bookIdentity,
          );
        }
      });
      unawaited(
        HomeworkStore.instance.reloadStudentHomework(widget.studentId),
      );
      if (mounted) {
        await _handleFlowChanged(
          preferredLinkedBookKey:
              _isChildAddMode ? _lockedLinkedBookKeyForFlow(_flowId) : null,
          forceNoBookSelection: _selectedLinkedBookKey == null,
        );
      }
      if (mounted) {
        _showDialogSnackBar('교재 바인딩을 해제했습니다.');
      }
      return true;
    } catch (e) {
      if (mounted) {
        _showDialogSnackBar('바인딩 해제에 실패했습니다: $e');
      }
      return false;
    }
  }

  Future<void> _showActiveTextbooksDialog() async {
    var groups = _groupLinkedTextbooks(_allLinkedTextbooks);
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (dialogContext) {
        return Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.all(24),
          child: UtilityGlassDialogShell(
            title: '활성 교재',
            icon: Icons.menu_book_rounded,
            preferredWidth: 680,
            maxHeight: 720,
            child: StatefulBuilder(
              builder: (context, setModalState) {
                return ListView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                  children: [
                    const Text(
                      '연결된 교재는 기본적으로 모두 표시됩니다. '
                      '과제 출제에서 숨길 교재만 직접 꺼 주세요.\n'
                      '바인딩 해제는 이 학생의 해당 교재 데이터를 영구 삭제합니다.',
                      style: TextStyle(
                        color: kDlgTextSub,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (groups.isEmpty) _buildNoticeCard('등록된 교재가 없습니다.'),
                    for (final entry in groups.entries) ...[
                      Padding(
                        padding: const EdgeInsets.only(top: 10, bottom: 6),
                        child: Text(
                          entry.key,
                          style: const TextStyle(
                            color: kDlgText,
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      Container(
                        decoration: BoxDecoration(
                          color: kDlgPanelBg,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: kDlgBorder),
                        ),
                        child: Column(
                          children: [
                            for (var i = 0; i < entry.value.length; i++) ...[
                              if (i > 0)
                                const Divider(
                                  height: 1,
                                  color: kDlgBorder,
                                ),
                              Builder(
                                builder: (context) {
                                  final link = entry.value[i];
                                  final enabled = _isTextbookActive(link);
                                  return Padding(
                                    padding: const EdgeInsets.only(right: 4),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: SwitchListTile(
                                            value: enabled,
                                            activeThumbColor: kDlgAccent,
                                            title: Text(
                                              link.bookName,
                                              style: const TextStyle(
                                                color: kDlgText,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                            subtitle: Text(
                                              link.flowName,
                                              style: const TextStyle(
                                                color: kDlgTextSub,
                                                fontSize: 12,
                                              ),
                                            ),
                                            onChanged: _isChildAddMode
                                                ? null
                                                : (next) async {
                                                    setState(() {
                                                      _textbookActiveOverrides =
                                                          {
                                                        ..._textbookActiveOverrides,
                                                        link.key: next,
                                                      };
                                                      if (!next &&
                                                          _selectedLinkedBookKey ==
                                                              link.key) {
                                                        _selectedLinkedBookKey =
                                                            null;
                                                        _units = const [];
                                                      }
                                                    });
                                                    setModalState(() {});
                                                    try {
                                                      await StudentTextbookActiveStore
                                                          .instance
                                                          .setEnabled(
                                                        studentId:
                                                            widget.studentId,
                                                        flowId: link.flowId,
                                                        bookId: link.bookId,
                                                        gradeLabel:
                                                            link.gradeLabel,
                                                        enabled: next,
                                                      );
                                                    } catch (_) {
                                                      if (mounted) {
                                                        _showDialogSnackBar(
                                                          '활성 교재 설정을 저장하지 못했습니다.',
                                                        );
                                                      }
                                                    }
                                                  },
                                          ),
                                        ),
                                        Tooltip(
                                          message: '바인딩 해제',
                                          child: IconButton(
                                            onPressed: _isChildAddMode
                                                ? null
                                                : () async {
                                                    final ok =
                                                        await _unbindLinkedTextbook(
                                                      link,
                                                    );
                                                    if (!ok || !mounted) {
                                                      return;
                                                    }
                                                    setModalState(() {
                                                      groups =
                                                          _groupLinkedTextbooks(
                                                        _allLinkedTextbooks,
                                                      );
                                                    });
                                                  },
                                            icon: const Icon(
                                              Icons.link_off_rounded,
                                              size: 20,
                                            ),
                                            color: const Color(0xFFC62828),
                                            disabledColor:
                                                kDlgTextSub.withValues(
                                              alpha: 0.35,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildFlowBookPicker() {
    if (_loadingAllFlowTextbooks) {
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '출처 선택',
            style: TextStyle(
              color: kDlgTextSub,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(height: 8),
          YggLoadingIndicator(size: 18),
        ],
      );
    }
    final hasDraftItems = _draftGroupItems.isNotEmpty;
    final draftBookKey = _currentDraftBookKey();
    final lockedBookKey = _lockedBookIdentity;
    final testFlow = _testFlow;
    final testFlowSelected = _isTestFlowId(_flowId);
    final visibleLinks = _allLinkedTextbooks
        .where(
          (link) => testFlowSelected
              ? _looksLikeWonriBook(link)
              : (!_isChildAddMode || link.flowId == _flowId),
        )
        .where(
          (link) =>
              _isTextbookActive(link) ||
              (_isChildAddMode &&
                  lockedBookKey != null &&
                  _bookIdentity(link) == lockedBookKey),
        )
        .toList(growable: false);
    final hasLockedCandidate = lockedBookKey != null &&
        visibleLinks.any((link) => _bookIdentity(link) == lockedBookKey);
    final canSelectNaesinSource = !_isChildAddMode &&
        testFlow != null &&
        (!hasDraftItems || _hasNaesinDraftItems());
    final canSelectCustomSource =
        !hasDraftItems || (!_hasNaesinDraftItems() && draftBookKey == null);
    Widget linkedBookChip(_LinkedTextbook link) {
      final linkBookKey = _bookIdentity(link);
      final selected = !_useNaesinSource &&
          !_useCustomSource &&
          _selectedLinkedBookKey == link.key;
      final disabledByDraft = hasDraftItems && linkBookKey != draftBookKey;
      final disabledByChildLock =
          _isChildAddMode && hasLockedCandidate && linkBookKey != lockedBookKey;
      final enabled = !disabledByDraft && !disabledByChildLock;
      return _buildPickerChip(
        label: '${link.bookName} · ${link.gradeLabel}',
        selected: selected,
        enabled: enabled,
        onTap: () async {
          if (!enabled) return;
          if (_selectedLinkedBookKey == link.key && !_useNaesinSource) {
            if (hasDraftItems || _isChildAddMode) {
              return;
            }
            setState(() {
              _selectedLinkedBookKey = null;
              _manualPageMode = false;
              _units = const <_BigUnitSelectionNode>[];
              _expandedLeftMidSmallsKey = null;
            });
            await _handleFlowChanged(forceNoBookSelection: true);
            return;
          }
          final keepTestFlow = _isTestFlowId(_flowId);
          setState(() {
            _useNaesinSource = false;
            _useCustomSource = false;
            _testOriginFlowId = keepTestFlow ? link.flowId : null;
            if (!keepTestFlow) _flowId = link.flowId;
            _selectedLinkedBookKey = link.key;
            _linkedHomeworkType = '교재';
            _syncLinkedHomeworkTypeToLinkedDraftItems('교재');
          });
          await _handleFlowChanged(
            preferredLinkedBookKey: link.key,
          );
        },
      );
    }

    double estimateBookChipWidth(_LinkedTextbook link) {
      final label = '${link.bookName} · ${link.gradeLabel}';
      final painter = TextPainter(
        text: TextSpan(
          text: label,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13.8,
          ),
        ),
        maxLines: 1,
        textDirection: Directionality.of(context),
      )..layout();
      return (painter.width + 42).clamp(120.0, 360.0);
    }

    Widget chipRow(List<_LinkedTextbook> links) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < links.length; i++) ...[
            if (i > 0) const SizedBox(width: 10),
            linkedBookChip(links[i]),
          ],
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '교재 선택',
                style: TextStyle(
                  color: kDlgTextSub,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            OutlinedButton.icon(
              onPressed:
                  _loadingAllFlowTextbooks ? null : _showActiveTextbooksDialog,
              icon: const Icon(Icons.tune_rounded, size: 17),
              label: const Text('활성 교재'),
              style: OutlinedButton.styleFrom(
                foregroundColor: kDlgText,
                side: const BorderSide(color: kDlgBorder),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _buildPickerChip(
              label: '내신 기출',
              selected: _useNaesinSource,
              enabled: canSelectNaesinSource,
              onTap: () async {
                if (!canSelectNaesinSource) return;
                if (hasDraftItems && !_hasNaesinDraftItems()) {
                  _showDialogSnackBar('교재 과제와 내신 과제는 같은 그룹에 섞어 추가할 수 없습니다.');
                  return;
                }
                await _enterNaesinStandaloneMode(testFlow.id);
              },
            ),
            _buildPickerChip(
              label: '모의 고사 기출',
              selected: false,
              enabled: false,
              onTap: () {},
            ),
            _buildPickerChip(
              label: '기타',
              selected: _useCustomSource,
              enabled: canSelectCustomSource,
              onTap: () async {
                if (!canSelectCustomSource) {
                  _showDialogSnackBar('교재 과제와 기타 과제는 같은 그룹에 섞어 추가할 수 없습니다.');
                  return;
                }
                if (_useCustomSource) {
                  setState(() => _useCustomSource = false);
                  return;
                }
                final restoreFlowId = (_testOriginFlowId ?? '').trim();
                setState(() {
                  _useNaesinSource = false;
                  _useCustomSource = true;
                  // 사용자화는 수동으로 하위과제를 담아야 하므로 자동 모드를 끈다.
                  _autoSubtaskMode = false;
                  _autoDraftFingerprint = null;
                  _detailsPanelExpanded = true;
                  _flowId = restoreFlowId.isNotEmpty ? restoreFlowId : _flowId;
                  _testOriginFlowId = null;
                  _selectedLinkedBookKey = null;
                  _manualPageMode = false;
                  _units = const <_BigUnitSelectionNode>[];
                  _expandedLeftMidSmallsKey = null;
                });
                await _handleFlowChanged(forceNoBookSelection: true);
              },
            ),
          ],
        ),
        if (visibleLinks.isNotEmpty) ...[
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final firstBookRow = <_LinkedTextbook>[];
              final secondBookRow = <_LinkedTextbook>[];
              final maxRowWidth =
                  constraints.maxWidth.isFinite ? constraints.maxWidth : 720.0;
              var usedWidth = 0.0;
              for (final link in visibleLinks) {
                final chipWidth = estimateBookChipWidth(link);
                final nextWidth = firstBookRow.isEmpty
                    ? chipWidth
                    : usedWidth + 10 + chipWidth;
                if (firstBookRow.isEmpty || nextWidth <= maxRowWidth) {
                  firstBookRow.add(link);
                  usedWidth = nextWidth;
                } else {
                  secondBookRow.add(link);
                }
              }
              return SizedBox(
                height: secondBookRow.isEmpty ? 44 : 98,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      chipRow(firstBookRow),
                      if (secondBookRow.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        chipRow(secondBookRow),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
        ],
        if (visibleLinks.isEmpty) ...[
          const SizedBox(height: 8),
          _buildNoticeCard(
            _allLinkedTextbooks.isEmpty
                ? '연결된 교재가 없습니다. 플로우 선택 상태로 하위 과제를 추가하세요.'
                : '현재 그룹 플로우에 연결된 교재가 없습니다.',
          ),
        ],
      ],
    );
  }

  Widget _buildMigratedExplorerRangePanel() {
    final controller = _migratedExplorer;
    if (controller == null) {
      return const Center(child: YggLoadingIndicator());
    }
    // 트리 패널 타이틀에 교재명+뒤로가기가 있으므로 별도 헤더는 두지 않는다.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 2,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: TextbookExplorerTreePanel(controller: controller),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 3,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: TextbookExplorerContent(controller: controller),
          ),
        ),
      ],
    );
  }

  Widget _buildRangeSelectionPanel({
    required _LinkedTextbook? selectedBook,
    required bool waitingSelectedBook,
  }) {
    if (_shouldShowNaesinPanel()) {
      return _buildNaesinRangePanel();
    }
    if (waitingSelectedBook) {
      return const Align(
        alignment: Alignment.topLeft,
        child: YggLoadingIndicator(size: 18),
      );
    }
    if (selectedBook == null) {
      return _buildNoticeCard('교재를 선택하면 단원 범위를 지정할 수 있습니다.');
    }
    if (selectedBook.isMigrated) {
      return _buildMigratedExplorerRangePanel();
    }

    final body = _buildMetadataTree(selectedBook);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildBookRangeHeader(selectedBook),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 44,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildPickerChip(
                    label: '페이지별',
                    selected: _rangePickerMode == 'page',
                    onTap: () {
                      if (_rangePickerMode == 'page') return;
                      setState(() {
                        _rangePickerMode = 'page';
                        _selectedProblemRegionIds.clear();
                      });
                      _refreshRangeAutoDraft();
                    },
                  ),
                  _buildPickerChip(
                    label: '유형별',
                    selected: _rangePickerMode == 'type',
                    enabled: _problemRegions.isNotEmpty,
                    onTap: () {
                      if (_problemRegions.isEmpty ||
                          _rangePickerMode == 'type') {
                        return;
                      }
                      setState(() {
                        _rangePickerMode = 'type';
                        _clearPageUnitSelection();
                      });
                      _refreshRangeAutoDraft();
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 21,
              child: TextField(
                controller: _page,
                keyboardType: TextInputType.text,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9\-~,/ ]')),
                ],
                style: const TextStyle(
                  color: kDlgText,
                  fontWeight: FontWeight.w600,
                ),
                decoration: _inputDecoration('페이지 입력', hint: '예: 10-12'),
                onSubmitted: (_) => _selectPagesFromPageInput(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: !_loadingMetadata && _units.isNotEmpty
              ? body
              : Scrollbar(
                  controller: _rangeFallbackScrollController,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _rangeFallbackScrollController,
                    child: body,
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildRightDetailPanel({
    required bool waitingSelectedBook,
    required _LinkedTextbook? selectedBook,
  }) {
    if (waitingSelectedBook) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: YggLoadingIndicator(size: 18),
      );
    }
    if (selectedBook == null) {
      return _useCustomSource
          ? _buildUnlinkedFlowMode()
          : _buildNoticeCard('기타를 선택하면 사용자화 과제를 직접 입력할 수 있습니다.');
    }
    if (_manualPageMode) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _title,
            style: const TextStyle(
              color: kDlgText,
              fontWeight: FontWeight.w600,
            ),
            decoration: _inputDecoration('하위 과제명', hint: '예: 교재 과제'),
          ),
          const SizedBox(height: 12),
          _buildManualPageInputs(),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildRangeInlineEditors(),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final selectedBook = _selectedLinkedBook;
    final hasBookSelection = _selectedLinkedBookKey != null;
    final hasMigratedBookSelection = selectedBook?.isMigrated == true;
    final showNaesinPanel = _shouldShowNaesinPanel();
    final showNaesinStandalone = _naesinStandaloneMode && showNaesinPanel;
    final showBody = _useCustomSource || hasBookSelection || showNaesinPanel;
    final waitingSelectedBook =
        _loadingFlowTextbooks && hasBookSelection && selectedBook == null;
    final mediaSize = MediaQuery.of(context).size;
    final maxDialogHeight =
        showNaesinPanel ? mediaSize.height * 0.98 : mediaSize.height * 0.94;
    const primaryActionHeight = 40.0;
    const dialogBottomPadding = 24.0;
    const bookRangeBottomSpacer = primaryActionHeight + dialogBottomPadding;
    const compactDialogWidth = 656.0;
    const naesinDialogMinWidth = 720.0;
    const naesinBodyHeight = 720.0;
    final naesinGridColumnCount = _naesinSchools.length;
    final double baseDialogWidth = (hasBookSelection
            ? (hasMigratedBookSelection ? 1520.0 : 1180.0)
            : (showNaesinPanel ? compactDialogWidth : compactDialogWidth)) *
        0.9;
    final naesinGridContentWidth = _kNaesinGridYearLabelWidth +
        _kNaesinGridLabelToCellsGap +
        naesinGridColumnCount * _kNaesinGridCellSize +
        math.max(0, naesinGridColumnCount - 1) * _kNaesinGridCellGap +
        72;
    final double targetDialogWidth = showNaesinPanel
        ? math.max(
            math.max(baseDialogWidth, naesinDialogMinWidth),
            naesinGridContentWidth,
          )
        : baseDialogWidth;
    final visualNaesinRows = _naesinGridVisualRowCount();
    final standaloneNaesinBodyHeight =
        (visualNaesinRows * (_kNaesinGridCellSize + _kNaesinGridCellGap)) + 166;
    final double bodyHeight = showNaesinPanel
        ? (showNaesinStandalone
            ? standaloneNaesinBodyHeight
                .clamp(360.0, naesinBodyHeight)
                .toDouble()
            : naesinBodyHeight)
        : (hasBookSelection ? 620 : (_useCustomSource ? 620 : 0));
    final double targetDialogHeight = showNaesinStandalone
        ? math.min(maxDialogHeight, bodyHeight + 76)
        : (showBody
            ? math.min(maxDialogHeight, bodyHeight + 360)
            : math.min(maxDialogHeight, 620));

    final rangeContent = _buildRangeSelectionPanel(
      selectedBook: selectedBook,
      waitingSelectedBook: waitingSelectedBook,
    );
    final Widget rangePanel = Expanded(
      flex: 7,
      // 교재 범위 선택은 외곽 회색 데코시트 없이 내부 패널만 표시한다.
      // 내신 패널은 기존 여백/구획이 레이아웃의 일부라 그대로 유지한다.
      child: showNaesinPanel
          ? Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: kDlgPanelBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: kDlgBorder),
              ),
              child: rangeContent,
            )
          : rangeContent,
    );
    Widget? secondaryActions() => _buildManualAddChildButton();

    Widget detailsPanel({
      required bool compact,
    }) {
      // 사용자화: 항상 펼침. 자동 모드: 상세 입력 숨김. 수동: 접힘/펼침.
      final showDetailEditors = _useCustomSource || !_autoSubtaskMode;
      final expanded =
          _useCustomSource || (!_autoSubtaskMode && _detailsPanelExpanded);
      final sectionTitle = _useCustomSource ? '사용자화 과제' : '하위 과제 정보';
      final canToggleDetails = showDetailEditors && !_useCustomSource;
      final showAutoCheckbox =
          !_useCustomSource && (hasBookSelection || showNaesinPanel);
      final header = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          children: [
            Expanded(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: canToggleDetails
                      ? () => setState(
                            () =>
                                _detailsPanelExpanded = !_detailsPanelExpanded,
                          )
                      : null,
                  child: Text(
                    sectionTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: UtilityGlassDialogTokens.iconColor,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ),
            if (showAutoCheckbox) ...[
              const SizedBox(width: 10),
              _buildAutoCheckbox(),
            ],
            if (canToggleDetails) ...[
              const SizedBox(width: 4),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => setState(
                    () => _detailsPanelExpanded = !_detailsPanelExpanded,
                  ),
                  child: Icon(
                    expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    color: UtilityGlassDialogTokens.iconColor.withValues(
                      alpha: 0.7,
                    ),
                    size: 24,
                  ),
                ),
              ),
            ],
          ],
        ),
      );
      final detailBody = _buildRightDetailPanel(
        waitingSelectedBook: waitingSelectedBook,
        selectedBook: selectedBook,
      );
      final pinChildActions = _useCustomSource || hasBookSelection;
      final showEmbeddedList = hasBookSelection || _useCustomSource;
      final addChildButton = secondaryActions();
      final panelChild = pinChildActions
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                if (showDetailEditors && expanded) ...[
                  SizedBox(height: hasMigratedBookSelection ? 12 : 10),
                  if (showEmbeddedList)
                    Flexible(
                      flex: 3,
                      child: Scrollbar(
                        controller: _inputPanelScrollController,
                        thumbVisibility: false,
                        child: SingleChildScrollView(
                          controller: _inputPanelScrollController,
                          child: detailBody,
                        ),
                      ),
                    )
                  else
                    Expanded(
                      child: Scrollbar(
                        controller: _inputPanelScrollController,
                        thumbVisibility: false,
                        child: SingleChildScrollView(
                          controller: _inputPanelScrollController,
                          child: detailBody,
                        ),
                      ),
                    ),
                ],
                if (addChildButton != null) ...[
                  SizedBox(height: hasMigratedBookSelection ? 14 : 12),
                  addChildButton,
                ],
                if (showEmbeddedList) ...[
                  SizedBox(height: hasMigratedBookSelection ? 14 : 12),
                  Expanded(
                    flex: (_autoSubtaskMode || !expanded) ? 1 : 2,
                    child: _buildEmbeddedDraftList(),
                  ),
                ],
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                header,
                if (showDetailEditors && expanded) ...[
                  SizedBox(height: hasMigratedBookSelection ? 12 : 10),
                  detailBody,
                ],
              ],
            );
      // 마이그레이션 교재는 바깥 데코 박스 없이 내용만 둔다.
      final panel = hasMigratedBookSelection
          ? panelChild
          : Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              decoration: BoxDecoration(
                color: const Color(0x221C1C1E),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: UtilityGlassDialogTokens.borderColor,
                  width: 0.5,
                ),
              ),
              child: panelChild,
            );
      return compact ? panel : Expanded(flex: 3, child: panel);
    }

    Widget topRegion() {
      // 마이그레이션 교재 선택 후엔 교재/플로우 칩 대신
      // 교재명·뒤로가기(기존 단원트리 상단)를 이 자리에 둔다.
      final hideSourcePickers = hasMigratedBookSelection;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hideSourcePickers && selectedBook != null) ...[
            _buildBookRangeHeader(selectedBook),
            const Divider(height: 1, thickness: 1, color: kDlgBorder),
            const SizedBox(height: 16),
          ] else ...[
            _buildFlowBookPicker(),
            const SizedBox(height: 12),
            const Divider(height: 1, thickness: 1, color: kDlgBorder),
            const SizedBox(height: 12),
            _buildFlowSelectorButtons(enabled: !hasBookSelection),
            const SizedBox(height: 18),
            const Divider(height: 1, thickness: 1, color: kDlgBorder),
            const SizedBox(height: 18),
          ],
          _buildGroupSettingsRow(),
        ],
      );
    }

    Widget bodyRegion() {
      if (!showBody) return const SizedBox.shrink();
      if (_useCustomSource) {
        return detailsPanel(compact: true);
      }
      final children = <Widget>[];
      if (showNaesinPanel || hasBookSelection) {
        children.add(rangePanel);
      }
      if (hasBookSelection) {
        children.add(const SizedBox(width: 12));
        children.add(detailsPanel(compact: false));
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      );
    }

    // 숙제 검사(분실/잊음/확인)와 동일: FAB 탭바 알약 높이·글자 크기.
    const actionButtonHeight = FabTabBarTokens.fabBarHeight - 12;
    final dlgColors = YggDialogColors.of(context);

    Widget actionChip({
      required String label,
      required VoidCallback onTap,
    }) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(actionButtonHeight / 2),
          onTap: onTap,
          child: Container(
            height: actionButtonHeight,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: dlgColors.chipBg,
              borderRadius: BorderRadius.circular(actionButtonHeight / 2),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: dlgColors.chipText,
                fontSize: FabTabBarTokens.fabBarLabelFontSize,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      );
    }

    Widget confirmButton({
      required String label,
      required VoidCallback? onTap,
    }) {
      final enabled = onTap != null;
      return Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(actionButtonHeight / 2),
          onTap: onTap,
          child: Container(
            height: actionButtonHeight,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: enabled ? kDlgAccent : dlgColors.chipBg,
              borderRadius: BorderRadius.circular(actionButtonHeight / 2),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: enabled ? Colors.white : dlgColors.chipText,
                fontSize: FabTabBarTokens.fabBarLabelFontSize,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      );
    }

    Widget destinationChip({
      required String label,
      required String value,
    }) {
      final selected = _selectedPlanDestination == value;
      return Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(actionButtonHeight / 2),
          onTap: () => setState(() => _selectedPlanDestination = value),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            height: actionButtonHeight,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? kDlgAccent : dlgColors.chipBg,
              borderRadius: BorderRadius.circular(actionButtonHeight / 2),
              border: Border.all(
                color: selected ? kDlgAccent : kDlgBorder,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : dlgColors.chipText,
                fontSize: FabTabBarTokens.fabBarLabelFontSize,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      );
    }

    Widget primaryActions() {
      if (showNaesinStandalone) {
        return Row(
          children: [
            const Spacer(),
            actionChip(
              label: '취소',
              onTap: () => Navigator.pop(context, null),
            ),
          ],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (widget.requirePlanDestination) ...[
            destinationChip(label: '오늘', value: 'in_class'),
            const SizedBox(width: 8),
            destinationChip(label: '숙제', value: 'homework'),
            const SizedBox(width: 8),
            destinationChip(label: '다음', value: 'next_session'),
          ] else
            actionChip(
              label: '취소',
              onTap: () => Navigator.pop(context, null),
            ),
          const Spacer(),
          confirmButton(
            label: _isChildAddMode ? '하위 과제 추가' : '과제 내기',
            onTap: _submitting ||
                    (widget.requirePlanDestination &&
                        _selectedPlanDestination == null)
                ? null
                : () => _submit(action: 'add'),
          ),
        ],
      );
    }

    Widget rightFormColumn({
      required bool includeBody,
      required bool includeBottomPadding,
    }) {
      return Column(
        mainAxisSize: includeBody ? MainAxisSize.max : MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          topRegion(),
          if (includeBody) ...[
            SizedBox(height: hasMigratedBookSelection ? 16 : 14),
            Expanded(
              child: hasBookSelection || _useCustomSource
                  ? detailsPanel(compact: true)
                  : bodyRegion(),
            ),
          ],
          if (showNaesinPanel && !hasBookSelection && !_useCustomSource) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                _buildAutoCheckbox(),
                const Spacer(),
                if (secondaryActions() case final naesinAdd?) naesinAdd,
              ],
            ),
          ],
          if (_isCurrentHomeworkTypeTest() && !showNaesinStandalone) ...[
            const SizedBox(height: 12),
            _buildTestConstraintOptionsCard(),
          ],
          const SizedBox(height: 10),
          primaryActions(),
          if (includeBottomPadding) const SizedBox(height: dialogBottomPadding),
        ],
      );
    }

    Widget dialogContent() {
      if (showNaesinStandalone) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: _buildNaesinStandalonePanel()),
            const SizedBox(height: 12),
            primaryActions(),
            const SizedBox(height: dialogBottomPadding),
          ],
        );
      }
      if (hasBookSelection) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 7,
              child: Column(
                children: [
                  rangePanel,
                  const SizedBox(height: bookRangeBottomSpacer),
                ],
              ),
            ),
            const SizedBox(width: 24),
            Expanded(
              flex: 3,
              child: rightFormColumn(
                includeBody: true,
                includeBottomPadding: true,
              ),
            ),
          ],
        );
      }
      return rightFormColumn(
        includeBody: showBody,
        includeBottomPadding: true,
      );
    }

    final horizontalInset = showNaesinPanel ? 24.0 : 40.0;
    final shellWidth = math
        .min(targetDialogWidth + 48, mediaSize.width - horizontalInset * 2)
        .toDouble();
    final shellHeight =
        math.min(targetDialogHeight + 72, mediaSize.height * 0.92).toDouble();
    // 보강/PDF/메모와 같이 하단 정렬 글래스 시트로 표시한다.
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      alignment: Alignment.bottomCenter,
      insetPadding: EdgeInsets.fromLTRB(
        horizontalInset,
        0,
        horizontalInset,
        18,
      ),
      child: UtilityGlassDialogShell(
        title: showNaesinStandalone
            ? '기출 선택'
            : (_isChildAddMode ? '하위 과제 추가' : '과제 추가'),
        icon: Icons.assignment_add,
        preferredWidth: shellWidth,
        maxHeight: shellHeight,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 130),
            curve: Curves.easeOutQuad,
            width: targetDialogWidth,
            constraints: BoxConstraints(maxHeight: targetDialogHeight),
            child: dialogContent(),
          ),
        ),
      ),
    );
  }
}

class _NaesinLinkedCellOption {
  const _NaesinLinkedCellOption({
    required this.linkKey,
    required this.cellLabel,
    required this.status,
  });

  final String linkKey;
  final String cellLabel;
  final _NaesinCellStatus? status;
}

class _NaesinPresetAutoValues {
  const _NaesinPresetAutoValues({
    this.presetId,
    required this.questionCount,
    this.questionPageCount,
    this.timeLimitMinutes,
  });

  final String? presetId;
  final int questionCount;
  final int? questionPageCount;
  final int? timeLimitMinutes;
}

class _NaesinCellStatus {
  const _NaesinCellStatus({
    required this.issuedAt,
    required this.firstIssuedAt,
    required this.elapsedMs,
    required this.isEnded,
    required this.isCompleted,
    required this.scoreLabel,
  });

  final DateTime? issuedAt;
  final DateTime? firstIssuedAt;
  final int elapsedMs;
  final bool isEnded;
  final bool isCompleted;
  final String scoreLabel;
}

class _DraftGroupItem {
  static const Object _unset = Object();

  final String key;
  final String type;
  final String? linkedBookKey;
  final String bookId;
  final String gradeLabel;
  final String? sourceUnitLevel;
  final String? sourceUnitPath;
  final List<Map<String, dynamic>> unitMappings;
  final String title;
  final String page;
  final String count;
  final String memo;
  final String content;
  final String body;
  final Color color;
  final int splitParts;
  final int? timeLimitMinutes;

  /// 권장 소요시간(분). 자동 제안을 사람이 수정했을 수 있는 확정값.
  final int? recommendedMinutes;

  /// 출제 시점 자동 계산 권장시간(분). 수정 여부 비교/통계용 원본.
  final int? recommendedMinutesAuto;
  final bool testMode;
  final String? testOriginFlowId;
  final String? pbPresetId;
  final String? naesinLinkKey;
  final String? naesinGroupTitle;

  const _DraftGroupItem({
    required this.key,
    required this.type,
    this.linkedBookKey,
    this.bookId = '',
    this.gradeLabel = '',
    this.sourceUnitLevel,
    this.sourceUnitPath,
    this.unitMappings = const <Map<String, dynamic>>[],
    required this.title,
    required this.page,
    required this.count,
    required this.memo,
    required this.content,
    required this.body,
    required this.color,
    required this.splitParts,
    this.timeLimitMinutes,
    this.recommendedMinutes,
    this.recommendedMinutesAuto,
    this.testMode = false,
    this.testOriginFlowId,
    this.pbPresetId,
    this.naesinLinkKey,
    this.naesinGroupTitle,
  });

  _DraftGroupItem copyWith({
    String? type,
    String? linkedBookKey,
    String? bookId,
    String? gradeLabel,
    String? sourceUnitLevel,
    String? sourceUnitPath,
    List<Map<String, dynamic>>? unitMappings,
    String? title,
    String? page,
    String? count,
    String? memo,
    String? content,
    String? body,
    Color? color,
    int? splitParts,
    Object? timeLimitMinutes = _unset,
    Object? recommendedMinutes = _unset,
    Object? recommendedMinutesAuto = _unset,
    bool? testMode,
    Object? testOriginFlowId = _unset,
    Object? pbPresetId = _unset,
    Object? naesinLinkKey = _unset,
    Object? naesinGroupTitle = _unset,
  }) {
    return _DraftGroupItem(
      key: key,
      type: type ?? this.type,
      linkedBookKey: linkedBookKey ?? this.linkedBookKey,
      bookId: bookId ?? this.bookId,
      gradeLabel: gradeLabel ?? this.gradeLabel,
      sourceUnitLevel: sourceUnitLevel ?? this.sourceUnitLevel,
      sourceUnitPath: sourceUnitPath ?? this.sourceUnitPath,
      unitMappings: unitMappings ?? this.unitMappings,
      title: title ?? this.title,
      page: page ?? this.page,
      count: count ?? this.count,
      memo: memo ?? this.memo,
      content: content ?? this.content,
      body: body ?? this.body,
      color: color ?? this.color,
      splitParts: splitParts ?? this.splitParts,
      timeLimitMinutes: identical(timeLimitMinutes, _unset)
          ? this.timeLimitMinutes
          : timeLimitMinutes as int?,
      recommendedMinutes: identical(recommendedMinutes, _unset)
          ? this.recommendedMinutes
          : recommendedMinutes as int?,
      recommendedMinutesAuto: identical(recommendedMinutesAuto, _unset)
          ? this.recommendedMinutesAuto
          : recommendedMinutesAuto as int?,
      testMode: testMode ?? this.testMode,
      testOriginFlowId: identical(testOriginFlowId, _unset)
          ? this.testOriginFlowId
          : testOriginFlowId as String?,
      pbPresetId: identical(pbPresetId, _unset)
          ? this.pbPresetId
          : pbPresetId as String?,
      naesinLinkKey: identical(naesinLinkKey, _unset)
          ? this.naesinLinkKey
          : naesinLinkKey as String?,
      naesinGroupTitle: identical(naesinGroupTitle, _unset)
          ? this.naesinGroupTitle
          : naesinGroupTitle as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'type': type,
      'title': title,
      'page': page,
      'count': count,
      'memo': memo,
      'content': content,
      'body': body,
      'color': color,
      'splitParts': splitParts.clamp(1, 4).toInt(),
      if (timeLimitMinutes != null && timeLimitMinutes! > 0)
        'timeLimitMinutes': timeLimitMinutes,
      if (recommendedMinutes != null && recommendedMinutes! > 0)
        'recommendedMinutes': recommendedMinutes,
      if (recommendedMinutesAuto != null && recommendedMinutesAuto! > 0)
        'recommendedMinutesAuto': recommendedMinutesAuto,
      if (testMode) 'testMode': true,
      if (testOriginFlowId != null && testOriginFlowId!.trim().isNotEmpty)
        'testOriginFlowId': testOriginFlowId!.trim(),
      if (pbPresetId != null && pbPresetId!.trim().isNotEmpty)
        'pbPresetId': pbPresetId!.trim(),
      if (bookId.trim().isNotEmpty) 'bookId': bookId.trim(),
      if (gradeLabel.trim().isNotEmpty) 'gradeLabel': gradeLabel.trim(),
      if (sourceUnitLevel != null && sourceUnitLevel!.trim().isNotEmpty)
        'sourceUnitLevel': sourceUnitLevel!.trim(),
      if (sourceUnitPath != null && sourceUnitPath!.trim().isNotEmpty)
        'sourceUnitPath': sourceUnitPath!.trim(),
      if (unitMappings.isNotEmpty)
        'unitMappings': List<Map<String, dynamic>>.from(
          unitMappings.map((e) => Map<String, dynamic>.from(e)),
        ),
      if (naesinLinkKey != null && naesinLinkKey!.trim().isNotEmpty)
        'naesinLinkKey': naesinLinkKey!.trim(),
      if (naesinGroupTitle != null && naesinGroupTitle!.trim().isNotEmpty)
        'naesinGroupTitle': naesinGroupTitle!.trim(),
    };
  }
}

class _LinkedTextbook {
  final String flowId;
  final String flowName;
  final String bookId;
  final String gradeLabel;
  final String bookName;
  final int orderIndex;
  final String migrationStatus;

  const _LinkedTextbook({
    required this.flowId,
    required this.flowName,
    required this.bookId,
    required this.gradeLabel,
    required this.bookName,
    required this.orderIndex,
    required this.migrationStatus,
  });

  String get key => '$flowId|$bookId|$gradeLabel';
  String get label => '$bookName · $gradeLabel';
  bool get isMigrated => migrationStatus == 'migrated';
}

class _IssuedSmallSummary {
  final DateTime? latestFinishedAt;
  final int completedCount;
  final int assignedCount;

  const _IssuedSmallSummary({
    required this.latestFinishedAt,
    required this.completedCount,
    this.assignedCount = 0,
  });
}

class _NaesinGradeOption {
  final String key;
  final String label;
  final EducationLevel level;
  final int grade;

  const _NaesinGradeOption({
    required this.key,
    required this.label,
    required this.level,
    required this.grade,
  });
}

class _NaesinCourseOption {
  final String key;
  final String label;

  const _NaesinCourseOption({
    required this.key,
    required this.label,
  });
}

class _SmallDragSnap {
  final bool selected;
  final bool explicitSelected;
  final Set<int> pages;

  _SmallDragSnap({
    required this.selected,
    required this.explicitSelected,
    required Set<int> pageSnapshot,
  }) : pages = Set<int>.from(pageSnapshot);

  factory _SmallDragSnap.fromNode(_SmallUnitSelectionNode s) {
    return _SmallDragSnap(
      selected: s.selected,
      explicitSelected: s.explicitSelected,
      pageSnapshot: s.selectedPages,
    );
  }
}

class _RightFlatEntry {
  final int smallIndex;
  final bool isHeader;
  final int? pageSortedIndex;

  const _RightFlatEntry({
    required this.smallIndex,
    required this.isHeader,
    this.pageSortedIndex,
  });
}

class _RightListHit {
  final int smallIndex;
  final bool isHeader;
  final int? pageSortedIndex;

  const _RightListHit({
    required this.smallIndex,
    required this.isHeader,
    this.pageSortedIndex,
  });
}

class _TypeProblemFlatEntry {
  final String kind;
  final int? displayPage;
  final String? typeGroupLabel;
  final List<_TextbookProblemRegion> groupRegions;
  final _TextbookProblemRegion? region;

  const _TypeProblemFlatEntry.pageHeader(int page)
      : kind = 'page',
        displayPage = page,
        typeGroupLabel = null,
        groupRegions = const <_TextbookProblemRegion>[],
        region = null;

  const _TypeProblemFlatEntry.typeHeader({
    required String label,
    required List<_TextbookProblemRegion> regions,
  })  : kind = 'type',
        displayPage = null,
        typeGroupLabel = label,
        groupRegions = regions,
        region = null;

  const _TypeProblemFlatEntry.problem(_TextbookProblemRegion problem)
      : kind = 'problem',
        displayPage = null,
        typeGroupLabel = null,
        groupRegions = const <_TextbookProblemRegion>[],
        region = problem;

  bool get isPageHeader => kind == 'page';
  bool get isTypeHeader => kind == 'type';
  bool get isProblem => region != null;
}

double _problemRegionCoordinate(dynamic bbox, int index) {
  if (bbox is! List || index < 0 || index >= bbox.length) {
    return double.infinity;
  }
  final value = bbox[index];
  if (value is num) return value.toDouble();
  return double.tryParse('$value') ?? double.infinity;
}

int _compareTextbookProblemRegionsBySource(
  _TextbookProblemRegion a,
  _TextbookProblemRegion b,
) {
  return compareTextbookProblemSourceOrder(
    TextbookProblemSourceOrderKey(
      bigOrder: a.bigOrder,
      midOrder: a.midOrder,
      subIndex: a.subIndex,
      subKey: a.subKey,
      page: a.displayPage,
      problemNumber: a.problemNumber,
      columnIndex: a.columnIndex,
      ymin: _problemRegionCoordinate(a.bbox1k, 0),
      xmin: _problemRegionCoordinate(a.bbox1k, 1),
      stableId: a.id,
    ),
    TextbookProblemSourceOrderKey(
      bigOrder: b.bigOrder,
      midOrder: b.midOrder,
      subIndex: b.subIndex,
      subKey: b.subKey,
      page: b.displayPage,
      problemNumber: b.problemNumber,
      columnIndex: b.columnIndex,
      ymin: _problemRegionCoordinate(b.bbox1k, 0),
      xmin: _problemRegionCoordinate(b.bbox1k, 1),
      stableId: b.id,
    ),
  );
}

class _TextbookProblemRegion {
  final String id;
  final int bigOrder;
  final int midOrder;
  final String subKey;
  final int subIndex;
  final String bigName;
  final String midName;
  final String smallName;
  final int? rawPage;
  final int displayPage;
  final String problemNumber;
  final String label;
  final String section;
  final bool isSetHeader;
  final bool isWonri;
  final String pbQuestionUid;
  final String typeKind;
  final String typeLabel;
  final String typeTitle;
  final int? typeOrder;
  final int columnIndex;
  final dynamic bbox1k;
  final dynamic itemRegion1k;

  const _TextbookProblemRegion({
    required this.id,
    required this.bigOrder,
    required this.midOrder,
    required this.subKey,
    this.subIndex = 0,
    required this.bigName,
    required this.midName,
    this.smallName = '',
    required this.rawPage,
    required this.displayPage,
    required this.problemNumber,
    required this.label,
    required this.section,
    required this.isSetHeader,
    this.isWonri = false,
    required this.pbQuestionUid,
    required this.typeKind,
    required this.typeLabel,
    required this.typeTitle,
    required this.typeOrder,
    this.columnIndex = 0,
    required this.bbox1k,
    required this.itemRegion1k,
  });

  String get typeGroupKey {
    if (isWonri) {
      // 개념원리: 소단원(표시명) × 세부 유형명으로 하위과제를 나눈다.
      final typeName = wonriTypeName;
      final smallId = smallName.trim().isNotEmpty ? smallName.trim() : subKey;
      return '$bigOrder|$midOrder|$smallId|$typeName';
    }
    final kind = typeKind.isEmpty ? 'section' : typeKind;
    final label = typeLabel.isEmpty ? section : typeLabel;
    return '$bigOrder|$midOrder|$subKey|$kind|${typeOrder ?? -1}|$label';
  }

  /// 개념원리 세부 유형명 (필수유형 content_group / STEP1 등).
  String get wonriTypeName => wonriTypeDisplayName(
        section: section,
        subKey: subKey,
        itemName: label,
        typeGroupKind: typeKind,
        typeGroupLabel: typeLabel,
        typeGroupTitle: typeTitle,
      );

  String get typeGroupLabel {
    if (isWonri) {
      final wonriName = wonriTypeName;
      if (wonriName.isNotEmpty) return wonriName;
    }
    if (typeTitle.isNotEmpty && typeLabel.isNotEmpty) {
      return '$typeLabel $typeTitle';
    }
    if (typeTitle.isNotEmpty) return typeTitle;
    if (typeLabel.isNotEmpty) return typeLabel;
    if (section.isNotEmpty) return section;
    return '유형 미분류';
  }

  String get difficultyLabel {
    if (label.trim().isNotEmpty) return label.trim();
    return '-';
  }

  Map<String, dynamic> toMappingJson() => {
        'cropId': id,
        'bigOrder': bigOrder,
        'midOrder': midOrder,
        'subKey': subKey,
        'subIndex': subIndex,
        'bigName': bigName,
        'midName': midName,
        'rawPage': rawPage,
        'displayPage': displayPage,
        'problemNumber': problemNumber,
        'columnIndex': columnIndex,
        'label': label,
        'section': section,
        'pbQuestionUid': pbQuestionUid,
        'typeKind': typeKind,
        'typeLabel': typeLabel,
        'typeTitle': typeTitle,
        'typeOrder': typeOrder,
        'bbox1k': bbox1k,
        'itemRegion1k': itemRegion1k,
      };
}

class _BigUnitSelectionNode {
  final String name;
  final int orderIndex;
  final List<_MidUnitSelectionNode> middles = <_MidUnitSelectionNode>[];
  bool selected = false;
  bool explicitSelected = false;

  _BigUnitSelectionNode({required this.name, required this.orderIndex});
}

class _MidUnitSelectionNode {
  final String name;
  final int orderIndex;

  /// 개념서(개념원리)면 true — 소단원은 sub_units 이고 문항 카운트는
  /// sub_key 가 아니라 페이지 범위로 배분한다.
  final bool isConcept;
  final List<_SmallUnitSelectionNode> smalls = <_SmallUnitSelectionNode>[];
  bool selected = false;
  bool explicitSelected = false;

  _MidUnitSelectionNode({
    required this.name,
    required this.orderIndex,
    this.isConcept = false,
  });
}

class _SmallUnitSelectionNode {
  final String name;
  final int orderIndex;
  final String subKey;
  final int? startPage;
  final int? endPage;
  final Map<int, int> pageCounts;

  /// 표시 쪽 번호별 완료 과제 횟수(과제 `page` 텍스트로 판별 가능할 때만).
  final Map<int, int> pageCompletedCounts = <int, int>{};

  /// 표시 쪽 번호별 내준 과제 횟수.
  final Map<int, int> pageAssignedCounts = <int, int>{};

  /// 체크박스 없이 펼친 페이지 칩에서 고른 쪽 번호(단원 전체가 아닐 때).
  final Set<int> selectedPages = <int>{};
  bool locked;
  bool draftBlocked;
  DateTime? finishedAt;
  int completedCount;
  int assignedCount;
  bool selected = false;
  bool explicitSelected = false;

  _SmallUnitSelectionNode({
    required this.name,
    required this.orderIndex,
    required this.subKey,
    required this.startPage,
    required this.endPage,
    required this.pageCounts,
    this.locked = false,
    this.draftBlocked = false,
    this.finishedAt,
    this.completedCount = 0,
    this.assignedCount = 0,
  });

  String get label {
    if (startPage == null || endPage == null) return name;
    if (startPage == endPage) return '$name ($startPage)';
    return '$name ($startPage-$endPage)';
  }
}

class _SelectedSmallUnit {
  final String bigName;
  final String midName;
  final String smallName;
  final int bigOrder;
  final int midOrder;
  final int smallOrder;
  final int? startPage;
  final int? endPage;
  final Map<int, int> pageCounts;

  const _SelectedSmallUnit({
    required this.bigName,
    required this.midName,
    required this.smallName,
    required this.bigOrder,
    required this.midOrder,
    required this.smallOrder,
    required this.startPage,
    required this.endPage,
    required this.pageCounts,
  });
}

class _UnitTask {
  final String title;
  final String page;
  final String count;
  final String content;
  final String sourceUnitLevel;
  final String sourceUnitPath;
  final List<Map<String, dynamic>> unitMappings;
  final bool allowAiSummaryTitle;

  const _UnitTask({
    required this.title,
    required this.page,
    required this.count,
    required this.content,
    required this.sourceUnitLevel,
    required this.sourceUnitPath,
    required this.unitMappings,
    required this.allowAiSummaryTitle,
  });
}

class _ExplicitSelectionAutoTitle {
  final String title;
  final String sourceUnitLevel;
  final String sourceUnitPath;
  final String pathSummary;

  const _ExplicitSelectionAutoTitle({
    required this.title,
    required this.sourceUnitLevel,
    required this.sourceUnitPath,
    required this.pathSummary,
  });
}

// 이어가기: 제목/색상은 고정 표기, 내용만 입력
class HomeworkContinueDialog extends StatefulWidget {
  final String studentId;
  final String title;
  final Color color;
  const HomeworkContinueDialog(
      {required this.studentId, required this.title, required this.color});
  @override
  State<HomeworkContinueDialog> createState() => _HomeworkContinueDialogState();
}

class _HomeworkContinueDialogState extends State<HomeworkContinueDialog> {
  late final TextEditingController _body;
  @override
  void initState() {
    super.initState();
    _body = ImeAwareTextEditingController(text: '');
  }

  @override
  void dispose() {
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: const Text('과제 이어가기', style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                      color: widget.color, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(widget.title,
                      style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 15,
                          fontWeight: FontWeight.w600)))
            ]),
            const SizedBox(height: 10),
            TextField(
              controller: _body,
              minLines: 2,
              maxLines: 4,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                  labelText: '내용',
                  labelStyle: TextStyle(color: Colors.white60),
                  enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.white24)),
                  focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Color(0xFF1976D2)))),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('취소', style: TextStyle(color: Colors.white70))),
        FilledButton(
          onPressed: () {
            Navigator.pop(context,
                {'studentId': widget.studentId, 'body': _body.text.trim()});
          },
          style:
              FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
          child: const Text('추가'),
        ),
      ],
    );
  }
}
