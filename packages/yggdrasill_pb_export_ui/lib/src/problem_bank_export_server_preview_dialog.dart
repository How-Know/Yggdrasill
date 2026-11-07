import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import 'pb_export_tokens.dart';

String _koreaTodayExamDate() {
  final now = DateTime.now().toUtc().add(const Duration(hours: 9));
  return '${now.year}.${now.month}.${now.day}';
}

class ProblemBankPreviewQuestionScoreEntry {
  const ProblemBankPreviewQuestionScoreEntry({
    required this.questionId,
    required this.questionNumber,
    this.defaultScore = 3,
  });

  final String questionId;
  final String questionNumber;
  final double defaultScore;
}

class ProblemBankPreviewRefreshRequest {
  const ProblemBankPreviewRefreshRequest({
    required this.subjectTitleText,
    required this.titlePageTopText,
    required this.titlePageGoalText,
    required this.timeLimitText,
    required this.pageColumnQuestionCounts,
    required this.columnLabelAnchors,
    required this.titlePageIndices,
    required this.titlePageHeaders,
    required this.coverPageTexts,
    required this.includeAcademyLogo,
    required this.includeCoverPage,
    this.includeCoverBlankPage = true,
    required this.includeAnswerSheet,
    required this.includeExplanation,
    required this.includeQuestionScore,
    required this.questionScoreByQuestionId,
    this.presetDisplayName = '',
    this.presetIdToUpdate = '',
    this.mathEngine = 'xelatex-v2',
    this.disableAutoLabels = false,
    this.assignmentFlowName = '',
  });

  final String subjectTitleText;
  final String titlePageTopText;
  final String titlePageGoalText;
  final String timeLimitText;
  final List<Map<String, dynamic>> pageColumnQuestionCounts;
  final List<Map<String, dynamic>> columnLabelAnchors;
  final List<int> titlePageIndices;
  final List<Map<String, dynamic>> titlePageHeaders;
  final Map<String, dynamic> coverPageTexts;
  final bool includeAcademyLogo;
  final bool includeCoverPage;
  final bool includeCoverBlankPage;
  final bool includeAnswerSheet;
  final bool includeExplanation;
  final bool includeQuestionScore;
  final Map<String, double> questionScoreByQuestionId;
  final String presetDisplayName;
  // 사용자가 프리셋 카드에서 이 다이얼로그에 진입한 경우, 해당 preset 의 id 가 들어온다.
  //   비어 있지 않으면 저장 시 "덮어쓰기"로 간주하고, 비어 있으면 "신규 저장"으로 처리한다.
  final String presetIdToUpdate;
  final String mathEngine;
  // 새로고침 시 서버의 '객관식 맨앞/유형 변경시 자동 라벨 생성' 로직을 끄기 위한 플래그.
  //   true 이면 서버는 columnLabelAnchors 에 들어있는 항목들만 사용하고
  //   mode 변화 기반 자동 라벨은 전혀 추가하지 않는다.
  final bool disableAutoLabels;
  final String assignmentFlowName;

  ProblemBankPreviewRefreshRequest copyWith({
    String? subjectTitleText,
    String? titlePageTopText,
    String? titlePageGoalText,
    String? timeLimitText,
    List<Map<String, dynamic>>? pageColumnQuestionCounts,
    List<Map<String, dynamic>>? columnLabelAnchors,
    List<int>? titlePageIndices,
    List<Map<String, dynamic>>? titlePageHeaders,
    Map<String, dynamic>? coverPageTexts,
    bool? includeAcademyLogo,
    bool? includeCoverPage,
    bool? includeCoverBlankPage,
    bool? includeAnswerSheet,
    bool? includeExplanation,
    bool? includeQuestionScore,
    Map<String, double>? questionScoreByQuestionId,
    String? presetDisplayName,
    String? presetIdToUpdate,
    String? mathEngine,
    bool? disableAutoLabels,
    String? assignmentFlowName,
  }) {
    return ProblemBankPreviewRefreshRequest(
      subjectTitleText: subjectTitleText ?? this.subjectTitleText,
      titlePageTopText: titlePageTopText ?? this.titlePageTopText,
      titlePageGoalText: titlePageGoalText ?? this.titlePageGoalText,
      timeLimitText: timeLimitText ?? this.timeLimitText,
      pageColumnQuestionCounts:
          pageColumnQuestionCounts ?? this.pageColumnQuestionCounts,
      columnLabelAnchors: columnLabelAnchors ?? this.columnLabelAnchors,
      titlePageIndices: titlePageIndices ?? this.titlePageIndices,
      titlePageHeaders: titlePageHeaders ?? this.titlePageHeaders,
      coverPageTexts: coverPageTexts ?? this.coverPageTexts,
      includeAcademyLogo: includeAcademyLogo ?? this.includeAcademyLogo,
      includeCoverPage: includeCoverPage ?? this.includeCoverPage,
      includeCoverBlankPage:
          includeCoverBlankPage ?? this.includeCoverBlankPage,
      includeAnswerSheet: includeAnswerSheet ?? this.includeAnswerSheet,
      includeExplanation: includeExplanation ?? this.includeExplanation,
      includeQuestionScore: includeQuestionScore ?? this.includeQuestionScore,
      questionScoreByQuestionId:
          questionScoreByQuestionId ?? this.questionScoreByQuestionId,
      presetDisplayName: presetDisplayName ?? this.presetDisplayName,
      presetIdToUpdate: presetIdToUpdate ?? this.presetIdToUpdate,
      mathEngine: mathEngine ?? this.mathEngine,
      disableAutoLabels: disableAutoLabels ?? this.disableAutoLabels,
      assignmentFlowName: assignmentFlowName ?? this.assignmentFlowName,
    );
  }
}

class ProblemBankPreviewRefreshResult {
  const ProblemBankPreviewRefreshResult({
    required this.pdfUrl,
    this.mathEngine = 'xelatex-v2',
    this.titlePageTopText = '2026학년도 대학수학능력시험 문제지',
    this.titlePageGoalText = '다시 풀기',
    this.timeLimitText = '',
    this.pageColumnQuestionCounts = const <Map<String, dynamic>>[],
    this.columnLabelAnchors = const <Map<String, dynamic>>[],
    this.titlePageIndices = const <int>[],
    this.titlePageHeaders = const <Map<String, dynamic>>[],
    this.coverPageTexts = const <String, dynamic>{},
    this.includeAcademyLogo = true,
    this.includeCoverPage = false,
    this.includeCoverBlankPage,
    this.includeAnswerSheet = false,
    this.includeExplanation = false,
    this.includeQuestionScore = false,
    this.questionScoreByQuestionId = const <String, double>{},
  });

  final String pdfUrl;
  final String mathEngine;
  final String titlePageTopText;
  final String titlePageGoalText;
  final String timeLimitText;
  final List<Map<String, dynamic>> pageColumnQuestionCounts;
  final List<Map<String, dynamic>> columnLabelAnchors;
  final List<int> titlePageIndices;
  final List<Map<String, dynamic>> titlePageHeaders;
  final Map<String, dynamic> coverPageTexts;
  final bool includeAcademyLogo;
  final bool includeCoverPage;
  final bool? includeCoverBlankPage;
  final bool includeAnswerSheet;
  final bool includeExplanation;
  final bool includeQuestionScore;
  final Map<String, double> questionScoreByQuestionId;
}

typedef ProblemBankPreviewRefreshCallback =
    Future<ProblemBankPreviewRefreshResult?> Function(
      ProblemBankPreviewRefreshRequest request,
    );

typedef ProblemBankPreviewGeneratePdfCallback =
    Future<void> Function(ProblemBankPreviewRefreshRequest request);

typedef ProblemBankPreviewPrintCallback =
    Future<bool> Function(String filePath);

typedef ProblemBankPreviewSaveSettingsCallback =
    Future<bool> Function(ProblemBankPreviewRefreshRequest request);

typedef ProblemBankPreviewCreateAssignmentCallback =
    Future<bool> Function(ProblemBankPreviewRefreshRequest request);

class _AssignmentPromptResult {
  const _AssignmentPromptResult({
    required this.displayName,
    required this.flowName,
  });

  final String displayName;
  final String flowName;
}

class ProblemBankExportServerPreviewDialog extends StatefulWidget {
  const ProblemBankExportServerPreviewDialog({
    super.key,
    required this.pdfUrl,
    required this.titleText,
    required this.expandedDialogSize,
    this.initialSubjectTitle = '수학 영역',
    this.initialTitlePageTopText = '2026학년도 대학수학능력시험 문제지',
    this.initialTitlePageGoalText = '다시 풀기',
    this.isAssignmentTemplate = false,
    this.isGyeongsinTemplate = false,
    this.isNeunginTemplate = false,
    this.isDaeryunTemplate = false,
    this.isDongdoTemplate = false,
    this.isSoseonTemplate = false,
    this.isOseongTemplate = false,
    this.isJeonghwaTemplate = false,
    this.isHwanggeumTemplate = false,
    this.initialTimeLimitText = '',
    this.layoutColumns = 1,
    this.maxQuestionsPerPage = 4,
    this.totalQuestionCount = 0,
    this.initialPageColumnQuestionCounts = const <Map<String, dynamic>>[],
    this.initialColumnLabelAnchors = const <Map<String, dynamic>>[],
    this.initialTitlePageIndices = const <int>[],
    this.initialTitlePageHeaders = const <Map<String, dynamic>>[],
    this.initialCoverPageTexts = const <String, dynamic>{},
    this.initialIncludeAcademyLogo = true,
    this.initialIncludeCoverPage = false,
    this.initialIncludeCoverBlankPage,
    this.initialIncludeAnswerSheet = false,
    this.initialIncludeExplanation = false,
    this.initialIncludeQuestionScore = false,
    this.initialMathEngine = 'xelatex-v2',
    this.initialQuestionScoreByQuestionId = const <String, double>{},
    this.questionScoreEntries = const <ProblemBankPreviewQuestionScoreEntry>[],
    this.initialEditingPresetId = '',
    this.initialEditingPresetName = '',
    this.assignmentFlowNames = const <String>[],
    this.onRefreshRequested,
    this.onGeneratePdfRequested,
    this.onPrintRequested,
    this.onSaveSettingsRequested,
    this.onCreateAssignmentRequested,
  });

  final String pdfUrl;
  final String titleText;
  final Size expandedDialogSize;
  final String initialSubjectTitle;
  final String initialTitlePageTopText;
  final String initialTitlePageGoalText;
  final bool isAssignmentTemplate;
  final bool isGyeongsinTemplate;
  final bool isNeunginTemplate;
  final bool isDaeryunTemplate;
  final bool isDongdoTemplate;
  final bool isSoseonTemplate;
  final bool isOseongTemplate;
  final bool isJeonghwaTemplate;
  final bool isHwanggeumTemplate;
  final String initialTimeLimitText;
  final int layoutColumns;
  final int maxQuestionsPerPage;
  final int totalQuestionCount;
  final List<Map<String, dynamic>> initialPageColumnQuestionCounts;
  final List<Map<String, dynamic>> initialColumnLabelAnchors;
  final List<int> initialTitlePageIndices;
  final List<Map<String, dynamic>> initialTitlePageHeaders;
  final Map<String, dynamic> initialCoverPageTexts;
  final bool initialIncludeAcademyLogo;
  final bool initialIncludeCoverPage;
  final bool? initialIncludeCoverBlankPage;
  final bool initialIncludeAnswerSheet;
  final bool initialIncludeExplanation;
  final bool initialIncludeQuestionScore;
  final String initialMathEngine;
  final Map<String, double> initialQuestionScoreByQuestionId;
  final List<ProblemBankPreviewQuestionScoreEntry> questionScoreEntries;
  // 프리셋 카드에서 진입한 경우에만 non-empty.
  //   → UI 에서 "저장"(덮어쓰기) / "새 세팅으로 저장" 두 버튼을 노출하기 위한 신호.
  final String initialEditingPresetId;
  final String initialEditingPresetName;
  final List<String> assignmentFlowNames;
  final ProblemBankPreviewRefreshCallback? onRefreshRequested;
  final ProblemBankPreviewGeneratePdfCallback? onGeneratePdfRequested;
  final ProblemBankPreviewPrintCallback? onPrintRequested;
  final ProblemBankPreviewSaveSettingsCallback? onSaveSettingsRequested;
  final ProblemBankPreviewCreateAssignmentCallback? onCreateAssignmentRequested;

  static const double _dialogFractionAtMaxWindow = 0.75;
  static const double _dialogMaxCurrentWindowFraction = 0.8;
  static const EdgeInsets _dialogInsetPadding = EdgeInsets.symmetric(
    horizontal: 20,
    vertical: 12,
  );

  static Size _previewDialogSizeFor(BuildContext context) {
    final windowSize = MediaQuery.sizeOf(context);
    final view = View.of(context);
    final screenSize = view.physicalSize / view.devicePixelRatio;
    final availableWidth = windowSize.width - _dialogInsetPadding.horizontal;
    final availableHeight = windowSize.height - _dialogInsetPadding.vertical;
    final maxWindowAvailableWidth =
        screenSize.width - _dialogInsetPadding.horizontal;
    final maxWindowAvailableHeight =
        screenSize.height - _dialogInsetPadding.vertical;
    return Size(
      math.min(
        maxWindowAvailableWidth * _dialogFractionAtMaxWindow,
        availableWidth * _dialogMaxCurrentWindowFraction,
      ),
      math.min(
        maxWindowAvailableHeight * _dialogFractionAtMaxWindow,
        availableHeight * _dialogMaxCurrentWindowFraction,
      ),
    );
  }

  static Future<void> open(
    BuildContext context, {
    required String pdfUrl,
    String titleText = '서버 PDF 미리보기',
    String initialSubjectTitle = '수학 영역',
    String initialTitlePageTopText = '2026학년도 대학수학능력시험 문제지',
    String initialTitlePageGoalText = '다시 풀기',
    bool isAssignmentTemplate = false,
    bool isGyeongsinTemplate = false,
    bool isNeunginTemplate = false,
    bool isDaeryunTemplate = false,
    bool isDongdoTemplate = false,
    bool isSoseonTemplate = false,
    bool isOseongTemplate = false,
    bool isJeonghwaTemplate = false,
    bool isHwanggeumTemplate = false,
    String initialTimeLimitText = '',
    int layoutColumns = 1,
    int maxQuestionsPerPage = 4,
    int totalQuestionCount = 0,
    List<Map<String, dynamic>> initialPageColumnQuestionCounts =
        const <Map<String, dynamic>>[],
    List<Map<String, dynamic>> initialColumnLabelAnchors =
        const <Map<String, dynamic>>[],
    List<int> initialTitlePageIndices = const <int>[],
    List<Map<String, dynamic>> initialTitlePageHeaders =
        const <Map<String, dynamic>>[],
    Map<String, dynamic> initialCoverPageTexts = const <String, dynamic>{},
    bool initialIncludeAcademyLogo = true,
    bool initialIncludeCoverPage = false,
    bool? initialIncludeCoverBlankPage,
    bool initialIncludeAnswerSheet = false,
    bool initialIncludeExplanation = false,
    bool initialIncludeQuestionScore = false,
    String initialMathEngine = 'xelatex-v2',
    Map<String, double> initialQuestionScoreByQuestionId =
        const <String, double>{},
    List<ProblemBankPreviewQuestionScoreEntry> questionScoreEntries =
        const <ProblemBankPreviewQuestionScoreEntry>[],
    String initialEditingPresetId = '',
    String initialEditingPresetName = '',
    List<String> assignmentFlowNames = const <String>[],
    ProblemBankPreviewRefreshCallback? onRefreshRequested,
    ProblemBankPreviewGeneratePdfCallback? onGeneratePdfRequested,
    ProblemBankPreviewPrintCallback? onPrintRequested,
    ProblemBankPreviewSaveSettingsCallback? onSaveSettingsRequested,
    ProblemBankPreviewCreateAssignmentCallback? onCreateAssignmentRequested,
  }) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final dialogSize = _previewDialogSizeFor(ctx);
        return PopScope(
          canPop: false,
          child: Dialog(
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            insetPadding: _dialogInsetPadding,
            child: ProblemBankExportServerPreviewDialog(
              pdfUrl: pdfUrl,
              titleText: titleText,
              expandedDialogSize: dialogSize,
              initialSubjectTitle: initialSubjectTitle,
              initialTitlePageTopText: initialTitlePageTopText,
              initialTitlePageGoalText: initialTitlePageGoalText,
              isAssignmentTemplate: isAssignmentTemplate,
              isGyeongsinTemplate: isGyeongsinTemplate,
              isNeunginTemplate: isNeunginTemplate,
              isDaeryunTemplate: isDaeryunTemplate,
              isDongdoTemplate: isDongdoTemplate,
              isSoseonTemplate: isSoseonTemplate,
              isOseongTemplate: isOseongTemplate,
              isJeonghwaTemplate: isJeonghwaTemplate,
              isHwanggeumTemplate: isHwanggeumTemplate,
              initialTimeLimitText: initialTimeLimitText,
              layoutColumns: layoutColumns,
              maxQuestionsPerPage: maxQuestionsPerPage,
              totalQuestionCount: totalQuestionCount,
              initialPageColumnQuestionCounts: initialPageColumnQuestionCounts,
              initialColumnLabelAnchors: initialColumnLabelAnchors,
              initialTitlePageIndices: initialTitlePageIndices,
              initialTitlePageHeaders: initialTitlePageHeaders,
              initialCoverPageTexts: initialCoverPageTexts,
              initialIncludeAcademyLogo: initialIncludeAcademyLogo,
              initialIncludeCoverPage: initialIncludeCoverPage,
              initialIncludeCoverBlankPage: initialIncludeCoverBlankPage,
              initialIncludeAnswerSheet: initialIncludeAnswerSheet,
              initialIncludeExplanation: initialIncludeExplanation,
              initialIncludeQuestionScore: initialIncludeQuestionScore,
              initialMathEngine: initialMathEngine,
              initialQuestionScoreByQuestionId:
                  initialQuestionScoreByQuestionId,
              questionScoreEntries: questionScoreEntries,
              initialEditingPresetId: initialEditingPresetId,
              initialEditingPresetName: initialEditingPresetName,
              assignmentFlowNames: assignmentFlowNames,
              onRefreshRequested: onRefreshRequested,
              onGeneratePdfRequested: onGeneratePdfRequested,
              onPrintRequested: onPrintRequested,
              onSaveSettingsRequested: onSaveSettingsRequested,
              onCreateAssignmentRequested: onCreateAssignmentRequested,
            ),
          ),
        );
      },
    );
  }

  @override
  State<ProblemBankExportServerPreviewDialog> createState() =>
      _ProblemBankExportServerPreviewDialogState();
}

class _ProblemBankExportServerPreviewDialogState
    extends State<ProblemBankExportServerPreviewDialog> {
  static const String _defaultTitlePageTopText = '2026학년도 대학수학능력시험 문제지';
  static const String _defaultTitlePageGoalText = '다시 풀기';
  static const double _minScale = 0.2;
  static const double _maxScale = 8;
  static const double _settingsPanelWidthFraction = 0.3;
  static const double _settingsPanelMinWidth = 320;
  static const double _settingsPanelMaxWidth = 420;
  static const double _settingsPanelCollapsedWidth = 48;
  static const double _settingsPanelGap = 12;
  static const EdgeInsets _dialogContentPadding = EdgeInsets.fromLTRB(
    14,
    12,
    14,
    12,
  );
  static const Color _panelSectionBg = Color(0xFF10171A);
  static const Color _panelBorder = Color(0xFF223131);
  static const Color _textPrimary = Color(0xFFEAF2F2);
  static const Color _textMuted = Color(0xFF9FB3B3);
  static const Color _accent = Color(0xFF33A373);
  static const double _firstPageAnchorTopPt = 16.0;
  static const double _firstPageAnchorPaddingTopPt = 27.0;
  static const double _otherPageAnchorTopPt = 9.2;
  static const double _otherPageAnchorPaddingTopPt = 35.8;

  double _expandedSettingsPanelWidthFor(double dialogWidth) {
    return (dialogWidth * _settingsPanelWidthFraction)
        .clamp(_settingsPanelMinWidth, _settingsPanelMaxWidth)
        .toDouble();
  }

  PreviewAcademyPanelStyle _settingsStyle(BuildContext context) {
    return FabTabBarTokens.previewAcademyPanelStyleFor(
      Theme.of(context).brightness,
    );
  }

  Color _settingsGroupedFill(BuildContext context) {
    return FabTabBarTokens.previewAcademyDialogGroupedFillColor(
      Theme.of(context).brightness,
    );
  }

  Border _settingsGroupedBorder(BuildContext context) {
    return FabTabBarTokens.groupedCardBorderFor(Theme.of(context).brightness);
  }

  final PdfViewerController _viewerController = PdfViewerController();
  late final TextEditingController _subjectController;
  late final TextEditingController _titlePageTopTextController;
  late final TextEditingController _titlePageGoalTextController;
  late final TextEditingController _timeLimitController;
  late final TextEditingController _coverTopTitleController;
  late final TextEditingController _coverSubjectTitleController;
  late final TextEditingController _coverPhraseController;
  late final TextEditingController _coverOrganizationController;
  late final TextEditingController _gyeongsinExamDateController;
  late final TextEditingController _gyeongsinPeriodLabelController;
  late final TextEditingController _gyeongsinSubjectCodeController;
  late final TextEditingController _gyeongsinSheetTypeController;
  late final TextEditingController _gyeongsinCoverExamTitleController;
  late final TextEditingController _gyeongsinHeaderExamTitleController;
  late final TextEditingController _gyeongsinSubjectNameController;
  late final TextEditingController _gyeongsinObjectiveCountController;
  late final TextEditingController _gyeongsinSubjectiveCountController;
  late final TextEditingController _gyeongsinEssayCountController;
  late final TextEditingController _gyeongsinObjectiveScoreController;
  late final TextEditingController _gyeongsinEssayScoreController;
  late final TextEditingController _gyeongsinTotalPageCountController;
  late final TextEditingController _gyeongsinFooterLabelController;
  late final TextEditingController _gyeongsinPageStartController;
  final List<TextEditingController> _coverGroupLabelControllers =
      <TextEditingController>[];
  final List<TextEditingController> _coverGroupPageRangeControllers =
      <TextEditingController>[];
  final List<List<TextEditingController>> _coverGroupItemNameControllers =
      <List<TextEditingController>>[];
  final List<List<TextEditingController>> _coverGroupItemPageControllers =
      <List<TextEditingController>>[];

  late String _currentPdfUrl;
  int _pageNumber = 1;
  int _pageCount = 0;
  double? _fitZoom;
  int _viewerRevision = 0;
  bool _isRefreshing = false;
  bool _isGeneratingPdf = false;
  bool _isPrintingPdf = false;
  bool _isSavingSettings = false;
  bool _isCreatingAssignment = false;
  bool _settingsPanelExpanded = true;
  String _mathEngine = 'xelatex-v2';
  String? _previewFailureMessage;
  String _lastPresetDisplayName = '';
  // 프리셋 카드에서 진입했을 때 해당 프리셋을 "덮어쓰기" 하기 위한 참조.
  //   빈 값이면 create-new 경로만 제공한다.
  String _editingPresetId = '';
  String _editingPresetName = '';
  late bool _includeAcademyLogo;
  late bool _includeCoverPage;
  late bool _includeCoverBlankPage;
  late bool _includeAnswerSheet;
  late bool _includeExplanation;
  late bool _includeQuestionScore;
  late List<ProblemBankPreviewQuestionScoreEntry> _questionScoreEntries;
  late Map<String, double> _questionScoreByQuestionId;
  late Map<int, List<int>> _pageOverrides;
  late List<List<int>> _computedPageColumnCounts;
  late Map<String, Map<String, dynamic>> _columnLabelAnchorMap;
  late Set<int> _labelPanelPageSet;
  late Set<int> _titlePageIndexSet;
  late Map<int, Map<String, String>> _titlePageHeaderMap;
  final Map<String, TextEditingController> _labelControllers =
      <String, TextEditingController>{};
  final Map<int, TextEditingController> _titleControllers =
      <int, TextEditingController>{};
  final Map<int, TextEditingController> _subtitleControllers =
      <int, TextEditingController>{};
  late String _initialStateSignature;

  @override
  void initState() {
    super.initState();
    _currentPdfUrl = widget.pdfUrl;
    _mathEngine = 'xelatex-v2';
    _previewFailureMessage = null;
    _editingPresetId = widget.initialEditingPresetId.trim();
    _editingPresetName = widget.initialEditingPresetName.trim();
    if (_editingPresetName.isNotEmpty) {
      _lastPresetDisplayName = _editingPresetName;
    }
    _subjectController = TextEditingController(
      text: widget.initialSubjectTitle,
    );
    _titlePageTopTextController = TextEditingController(
      text: widget.initialTitlePageTopText.trim().isNotEmpty
          ? widget.initialTitlePageTopText.trim()
          : _defaultTitlePageTopText,
    );
    _titlePageGoalTextController = TextEditingController(
      text: widget.initialTitlePageGoalText.trim().isNotEmpty
          ? widget.initialTitlePageGoalText.trim()
          : _defaultTitlePageGoalText,
    );
    _timeLimitController = TextEditingController(
      text: widget.initialTimeLimitText.trim(),
    );
    _coverTopTitleController = TextEditingController();
    _coverSubjectTitleController = TextEditingController();
    _coverPhraseController = TextEditingController();
    _coverOrganizationController = TextEditingController();
    _gyeongsinExamDateController = TextEditingController();
    _gyeongsinPeriodLabelController = TextEditingController();
    _gyeongsinSubjectCodeController = TextEditingController();
    _gyeongsinSheetTypeController = TextEditingController();
    _gyeongsinObjectiveScoreController = TextEditingController();
    _gyeongsinEssayScoreController = TextEditingController();
    _gyeongsinCoverExamTitleController = TextEditingController();
    _gyeongsinHeaderExamTitleController = TextEditingController();
    _gyeongsinSubjectNameController = TextEditingController();
    _gyeongsinObjectiveCountController = TextEditingController();
    _gyeongsinSubjectiveCountController = TextEditingController();
    _gyeongsinEssayCountController = TextEditingController();
    _gyeongsinTotalPageCountController = TextEditingController();
    _gyeongsinFooterLabelController = TextEditingController();
    _gyeongsinPageStartController = TextEditingController();
    _syncCoverPageTextControllers(
      _normalizeCoverPageTexts(widget.initialCoverPageTexts),
    );
    _includeAcademyLogo = widget.initialIncludeAcademyLogo;
    _includeCoverPage = widget.initialIncludeCoverPage;
    _includeCoverBlankPage = widget.initialIncludeCoverBlankPage ??
        _readCoverBlankPageFlag(
          widget.initialCoverPageTexts['includeCoverBlankPage'],
        );
    _includeAnswerSheet = widget.initialIncludeAnswerSheet;
    _includeExplanation = widget.initialIncludeExplanation;
    _includeQuestionScore = widget.initialIncludeQuestionScore;
    _questionScoreEntries = _normalizeQuestionScoreEntries(
      widget.questionScoreEntries,
    );
    _questionScoreByQuestionId = _normalizeQuestionScoreMap(
      widget.initialQuestionScoreByQuestionId,
    );
    _pageOverrides = _readInitialPageOverrides();
    _computedPageColumnCounts = _recomputePageColumnCounts();
    _columnLabelAnchorMap = _readInitialColumnLabelAnchors();
    _titlePageHeaderMap = _readInitialTitlePageHeaders();
    _labelPanelPageSet = _labelPagesFromAnchorMap(_columnLabelAnchorMap);
    _titlePageIndexSet = _normalizeTitlePageIndices(<dynamic>[
      ...widget.initialTitlePageIndices,
      ..._titlePageHeaderMap.keys,
    ]);
    _syncPageScopedUiState();
    _initialStateSignature = _currentStateSignature();
  }

  @override
  void dispose() {
    for (final controller in _labelControllers.values) {
      controller.dispose();
    }
    for (final controller in _titleControllers.values) {
      controller.dispose();
    }
    for (final controller in _subtitleControllers.values) {
      controller.dispose();
    }
    _subjectController.dispose();
    _titlePageTopTextController.dispose();
    _titlePageGoalTextController.dispose();
    _timeLimitController.dispose();
    _coverTopTitleController.dispose();
    _coverSubjectTitleController.dispose();
    _coverPhraseController.dispose();
    _coverOrganizationController.dispose();
    _gyeongsinExamDateController.dispose();
    _gyeongsinPeriodLabelController.dispose();
    _gyeongsinSubjectCodeController.dispose();
    _gyeongsinSheetTypeController.dispose();
    _gyeongsinObjectiveScoreController.dispose();
    _gyeongsinEssayScoreController.dispose();
    _gyeongsinCoverExamTitleController.dispose();
    _gyeongsinHeaderExamTitleController.dispose();
    _gyeongsinSubjectNameController.dispose();
    _gyeongsinObjectiveCountController.dispose();
    _gyeongsinSubjectiveCountController.dispose();
    _gyeongsinEssayCountController.dispose();
    _gyeongsinTotalPageCountController.dispose();
    _gyeongsinFooterLabelController.dispose();
    _gyeongsinPageStartController.dispose();
    _disposeCoverGroupControllers();
    super.dispose();
  }

  bool get _isTwoColumnLayout => widget.layoutColumns == 2;

  int get _maxEditablePageCount {
    if (_isTwoColumnLayout) {
      return math.max(1, _computedPageColumnCounts.length);
    }
    return math.max(1, _pageCount);
  }

  Set<int> _normalizeTitlePageIndices(Iterable<dynamic>? source) {
    final maxPage = _maxEditablePageCount;
    final out = <int>{1};
    if (source != null) {
      for (final one in source) {
        final page = int.tryParse('$one');
        if (page == null || page <= 0) continue;
        if (page > maxPage) continue;
        out.add(page);
      }
    }
    return out;
  }

  double _sanitizeQuestionScore(num value) {
    final normalized = value.toDouble();
    if (!normalized.isFinite) return 3;
    if (normalized < 0) return 0;
    if (normalized > 999) return 999;
    return normalized;
  }

  List<ProblemBankPreviewQuestionScoreEntry> _normalizeQuestionScoreEntries(
    List<ProblemBankPreviewQuestionScoreEntry> source,
  ) {
    if (source.isEmpty) return const <ProblemBankPreviewQuestionScoreEntry>[];
    final out = <ProblemBankPreviewQuestionScoreEntry>[];
    final seen = <String>{};
    for (final entry in source) {
      final questionId = entry.questionId.trim();
      if (questionId.isEmpty || seen.contains(questionId)) continue;
      seen.add(questionId);
      final questionNumber = entry.questionNumber.trim().isNotEmpty
          ? entry.questionNumber.trim()
          : '${out.length + 1}';
      out.add(
        ProblemBankPreviewQuestionScoreEntry(
          questionId: questionId,
          questionNumber: questionNumber,
          defaultScore: _sanitizeQuestionScore(entry.defaultScore),
        ),
      );
    }
    return out;
  }

  Map<String, double> _normalizeQuestionScoreMap(Map<String, double> source) {
    final out = <String, double>{};
    for (final entry in _questionScoreEntries) {
      final score = source[entry.questionId];
      out[entry.questionId] = _sanitizeQuestionScore(
        score ?? entry.defaultScore,
      );
    }
    return out;
  }

  Map<String, double> _questionScorePayload() {
    if (_questionScoreEntries.isEmpty) return const <String, double>{};
    final out = <String, double>{};
    for (final entry in _questionScoreEntries) {
      final score = _questionScoreByQuestionId[entry.questionId];
      out[entry.questionId] = _sanitizeQuestionScore(
        score ?? entry.defaultScore,
      );
    }
    return out;
  }

  String _formatScoreValue(num value) {
    final safe = value.toDouble();
    if (!safe.isFinite) return '0';
    if ((safe - safe.round()).abs() < 0.0001) return '${safe.round()}';
    return safe.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');
  }

  double? _parseScoreInput(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final parsed = double.tryParse(text);
    if (parsed == null || !parsed.isFinite) return null;
    return _sanitizeQuestionScore(parsed);
  }

  double _questionScoreTotal(Map<String, double> source) {
    var total = 0.0;
    for (final entry in _questionScoreEntries) {
      total += _sanitizeQuestionScore(
        source[entry.questionId] ?? entry.defaultScore,
      );
    }
    return total;
  }

  Future<void> _openQuestionScoreSettingsDialog() async {
    if (_questionScoreEntries.isEmpty) return;
    final draft = _questionScorePayload();
    final controllers = <String, TextEditingController>{};
    for (final entry in _questionScoreEntries) {
      controllers[entry.questionId] = TextEditingController(
        text: _formatScoreValue(draft[entry.questionId] ?? entry.defaultScore),
      );
    }
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (context, setDialogState) {
              final total = _questionScoreTotal(draft);
              return AlertDialog(
                backgroundColor: kDlgBg,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: _panelBorder),
                ),
                titlePadding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
                contentPadding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
                actionsPadding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
                title: const Text(
                  '문항별 점수 설정',
                  style: TextStyle(
                    color: _textPrimary,
                    fontSize: 14.4,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                content: SizedBox(
                  width: 420,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 520),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final entry in _questionScoreEntries)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 70,
                                    child: Text(
                                      '${entry.questionNumber}번',
                                      style: const TextStyle(
                                        color: _textPrimary,
                                        fontSize: 12.6,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: TextField(
                                      controller: controllers[entry.questionId],
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                            decimal: true,
                                            signed: false,
                                          ),
                                      style: const TextStyle(
                                        color: _textPrimary,
                                        fontSize: 12.8,
                                        fontWeight: FontWeight.w700,
                                      ),
                                      decoration: const InputDecoration(
                                        isDense: true,
                                        filled: true,
                                        fillColor: Color(0xFF0E161B),
                                        enabledBorder: OutlineInputBorder(
                                          borderSide: BorderSide(
                                            color: _panelBorder,
                                          ),
                                        ),
                                        focusedBorder: OutlineInputBorder(
                                          borderSide: BorderSide(
                                            color: _accent,
                                          ),
                                        ),
                                        contentPadding: EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 9,
                                        ),
                                        suffixText: '점',
                                        suffixStyle: TextStyle(
                                          color: _textMuted,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      onChanged: (value) {
                                        final parsed = _parseScoreInput(value);
                                        if (parsed == null) return;
                                        setDialogState(() {
                                          draft[entry.questionId] = parsed;
                                        });
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          const SizedBox(height: 6),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
                            decoration: BoxDecoration(
                              color: _panelSectionBg,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: _panelBorder),
                            ),
                            child: Text(
                              '총점: ${_formatScoreValue(total)}점',
                              style: const TextStyle(
                                color: _textPrimary,
                                fontSize: 12.8,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () {
                      for (final entry in _questionScoreEntries) {
                        final restored = _sanitizeQuestionScore(
                          entry.defaultScore,
                        );
                        draft[entry.questionId] = restored;
                        controllers[entry.questionId]?.text = _formatScoreValue(
                          restored,
                        );
                      }
                      setDialogState(() {});
                    },
                    child: const Text('기본값 복원'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('취소'),
                  ),
                  FilledButton(
                    onPressed: () {
                      setState(() {
                        _questionScoreByQuestionId = _normalizeQuestionScoreMap(
                          draft,
                        );
                      });
                      Navigator.of(dialogContext).pop();
                    },
                    child: const Text('적용'),
                  ),
                ],
              );
            },
          );
        },
      );
    } finally {
      for (final controller in controllers.values) {
        controller.dispose();
      }
    }
  }

  void _syncPageScopedUiState() {
    final maxPage = _maxEditablePageCount;
    _labelPanelPageSet = _labelPanelPageSet
        .where((page) => page >= 1 && page <= maxPage)
        .toSet();
    _titlePageIndexSet =
        _titlePageIndexSet.where((page) => page >= 1 && page <= maxPage).toSet()
          ..add(1);
    _titlePageHeaderMap = Map<int, Map<String, String>>.fromEntries(
      _titlePageHeaderMap.entries
          .where((entry) => entry.key >= 1 && entry.key <= maxPage)
          .map(
            (entry) => MapEntry(entry.key, <String, String>{
              'title': entry.value['title'] ?? '',
              'subtitle': entry.value['subtitle'] ?? '',
            }),
          ),
    );
    if (_isTwoColumnLayout) {
      _columnLabelAnchorMap = Map<String, Map<String, dynamic>>.fromEntries(
        _columnLabelAnchorMap.entries.where((entry) {
          final row = entry.value;
          final page = int.tryParse('${row['page'] ?? 0}') ?? 0;
          final col = int.tryParse('${row['columnIndex'] ?? -1}') ?? -1;
          final rowIndex = int.tryParse('${row['rowIndex'] ?? 0}') ?? -1;
          if (page < 1 || page > _computedPageColumnCounts.length) return false;
          if (col < 0 || col > 1) return false;
          if (rowIndex < 0) return false;
          if (col == 1 && rowIndex == 99) return true;
          final pageCounts = _computedPageColumnCounts[page - 1];
          final rowLimit = col < pageCounts.length ? pageCounts[col] : 0;
          return rowIndex < rowLimit;
        }),
      );
    }
    for (final pageNo in _titlePageIndexSet) {
      _ensureTitleHeaderForPage(pageNo);
    }
    _syncTitleHeaderControllers();
    final pageOneTitle = (_titlePageHeaderMap[1]?['title'] ?? '').trim();
    if (pageOneTitle.isNotEmpty && _subjectController.text != pageOneTitle) {
      _subjectController.text = pageOneTitle;
    }
  }

  Map<int, Map<String, String>> _parseTitlePageHeaders(
    List<Map<String, dynamic>> source,
  ) {
    final maxPage = _maxEditablePageCount;
    final out = <int, Map<String, String>>{};
    for (final one in source) {
      final pageRaw = int.tryParse(
        '${one['page'] ?? one['pageIndex'] ?? one['pageNo'] ?? one['pageNumber'] ?? ''}',
      );
      if (pageRaw == null || pageRaw <= 0 || pageRaw > maxPage) continue;
      final title = '${one['title'] ?? one['subjectTitleText'] ?? ''}'
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final subtitle =
          '${one['subtitle'] ?? one['subTitle'] ?? one['sub'] ?? ''}'
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
      if (title.isEmpty && subtitle.isEmpty) continue;
      out[pageRaw] = <String, String>{'title': title, 'subtitle': subtitle};
    }
    return out;
  }

  Map<int, Map<String, String>> _readInitialTitlePageHeaders() {
    final parsed = _parseTitlePageHeaders(widget.initialTitlePageHeaders);
    if (!parsed.containsKey(1)) {
      final initialTitle = widget.initialSubjectTitle.trim().isNotEmpty
          ? widget.initialSubjectTitle.trim()
          : '수학 영역';
      parsed[1] = <String, String>{'title': initialTitle, 'subtitle': ''};
    }
    return parsed;
  }

  void _ensureTitleHeaderForPage(int pageNo) {
    final fallback =
        (_titlePageHeaderMap[1]?['title'] ?? _subjectController.text)
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
    final baseTitle = fallback.isNotEmpty ? fallback : '수학 영역';
    final existing = _titlePageHeaderMap[pageNo];
    if (existing == null) {
      _titlePageHeaderMap[pageNo] = <String, String>{
        'title': baseTitle,
        'subtitle': '',
      };
      return;
    }
    final currentTitle = (existing['title'] ?? '').trim();
    if (currentTitle.isEmpty) {
      _titlePageHeaderMap[pageNo] = <String, String>{
        'title': baseTitle,
        'subtitle': existing['subtitle'] ?? '',
      };
    }
  }

  void _syncTitleHeaderControllers() {
    final validPages = _titlePageHeaderMap.keys.toSet();
    final staleTitlePages = _titleControllers.keys
        .where((pageNo) => !validPages.contains(pageNo))
        .toList(growable: false);
    for (final pageNo in staleTitlePages) {
      _titleControllers.remove(pageNo)?.dispose();
    }
    final staleSubtitlePages = _subtitleControllers.keys
        .where((pageNo) => !validPages.contains(pageNo))
        .toList(growable: false);
    for (final pageNo in staleSubtitlePages) {
      _subtitleControllers.remove(pageNo)?.dispose();
    }
    for (final pageNo in validPages) {
      final header = _titlePageHeaderMap[pageNo] ?? const <String, String>{};
      final title = header['title'] ?? '';
      final subtitle = header['subtitle'] ?? '';
      final titleController = _titleControllers[pageNo];
      if (titleController != null && titleController.text != title) {
        titleController.text = title;
      }
      final subtitleController = _subtitleControllers[pageNo];
      if (subtitleController != null && subtitleController.text != subtitle) {
        subtitleController.text = subtitle;
      }
    }
  }

  bool _isLabelPanelVisible(int pageNo) => _labelPanelPageSet.contains(pageNo);

  void _toggleLabelPanel(int pageNo) {
    if (pageNo <= 0) return;
    setState(() {
      if (_labelPanelPageSet.contains(pageNo)) {
        _labelPanelPageSet.remove(pageNo);
      } else {
        _labelPanelPageSet.add(pageNo);
      }
      _syncPageScopedUiState();
    });
  }

  bool _isTitlePage(int pageNo) => _titlePageIndexSet.contains(pageNo);

  void _toggleTitlePage(int pageNo) {
    if (pageNo <= 1) return;
    setState(() {
      if (_titlePageIndexSet.contains(pageNo)) {
        _titlePageIndexSet.remove(pageNo);
        _titlePageHeaderMap.remove(pageNo);
        _titleControllers.remove(pageNo)?.dispose();
        _subtitleControllers.remove(pageNo)?.dispose();
      } else {
        _titlePageIndexSet.add(pageNo);
        _ensureTitleHeaderForPage(pageNo);
      }
      _syncPageScopedUiState();
    });
  }

  TextEditingController _titleControllerForPage(int pageNo) {
    final existing = _titleControllers[pageNo];
    if (existing != null) return existing;
    _ensureTitleHeaderForPage(pageNo);
    final controller = TextEditingController(
      text: _titlePageHeaderMap[pageNo]?['title'] ?? '',
    );
    _titleControllers[pageNo] = controller;
    return controller;
  }

  TextEditingController _subtitleControllerForPage(int pageNo) {
    final existing = _subtitleControllers[pageNo];
    if (existing != null) return existing;
    _ensureTitleHeaderForPage(pageNo);
    final controller = TextEditingController(
      text: _titlePageHeaderMap[pageNo]?['subtitle'] ?? '',
    );
    _subtitleControllers[pageNo] = controller;
    return controller;
  }

  void _setTitleHeader({required int pageNo, String? title, String? subtitle}) {
    _ensureTitleHeaderForPage(pageNo);
    final prev = _titlePageHeaderMap[pageNo] ?? const <String, String>{};
    final normalizedTitle = (title ?? prev['title'] ?? '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final normalizedSubtitle = (subtitle ?? prev['subtitle'] ?? '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    _titlePageHeaderMap[pageNo] = <String, String>{
      'title': normalizedTitle,
      'subtitle': normalizedSubtitle,
    };
  }

  List<int> get _baseColumnCounts {
    if (!_isTwoColumnLayout) return const <int>[1, 0];
    final safePerPage = widget.maxQuestionsPerPage <= 0
        ? 4
        : widget.maxQuestionsPerPage;
    final left = (safePerPage / 2).ceil();
    final right = math.max(0, safePerPage - left);
    return <int>[left, right];
  }

  Map<int, List<int>> _parsePageOverrides(List<Map<String, dynamic>> source) {
    if (!_isTwoColumnLayout) return <int, List<int>>{};
    final out = <int, List<int>>{};
    for (final one in source) {
      final pageRaw = int.tryParse(
        '${one['pageIndex'] ?? one['page'] ?? one['pageNo'] ?? one['pageNumber'] ?? ''}',
      );
      final leftRaw = int.tryParse(
        '${one['left'] ?? one['leftCount'] ?? one['col1'] ?? ''}',
      );
      final rightRaw = int.tryParse(
        '${one['right'] ?? one['rightCount'] ?? one['col2'] ?? ''}',
      );
      if (leftRaw == null || rightRaw == null) continue;
      if (leftRaw < 0 || rightRaw < 0) continue;
      if (leftRaw + rightRaw <= 0) continue;
      final pageIndex = pageRaw == null ? out.length : math.max(0, pageRaw - 1);
      out[pageIndex] = <int>[leftRaw, rightRaw];
    }
    return out;
  }

  Map<int, List<int>> _readInitialPageOverrides() {
    return _parsePageOverrides(widget.initialPageColumnQuestionCounts);
  }

  String _anchorKey(int pageIndex, int columnIndex, {int rowIndex = 0}) =>
      '${pageIndex + 1}:$columnIndex:$rowIndex';

  int? _parseAnchorPageIndex(dynamic raw) {
    final text = '$raw'.trim().toLowerCase();
    if (text.isEmpty || text == 'first') return 0;
    if (text == 'all') return 0;
    final parsed = int.tryParse(text);
    if (parsed == null || parsed <= 0) return null;
    return parsed - 1;
  }

  double _defaultAnchorTopForPage(int pageIndex) {
    return pageIndex == 0 ? _firstPageAnchorTopPt : _otherPageAnchorTopPt;
  }

  double _defaultAnchorPaddingForPage(int pageIndex) {
    return pageIndex == 0
        ? _firstPageAnchorPaddingTopPt
        : _otherPageAnchorPaddingTopPt;
  }

  Map<String, Map<String, dynamic>> _parseColumnLabelAnchors(
    List<Map<String, dynamic>> source,
  ) {
    if (!_isTwoColumnLayout) return <String, Map<String, dynamic>>{};
    final out = <String, Map<String, dynamic>>{};
    for (final one in source) {
      final pageIndex = _parseAnchorPageIndex(
        one['page'] ?? one['pageIndex'] ?? one['pageNo'] ?? one['pageNumber'],
      );
      final columnIndex = int.tryParse(
        '${one['columnIndex'] ?? one['column'] ?? one['col'] ?? ''}',
      );
      final rowIndex =
          int.tryParse(
            '${one['rowIndex'] ?? one['row'] ?? one['slotRowIndex'] ?? ''}',
          ) ??
          0;
      final label = '${one['label'] ?? one['text'] ?? ''}'
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final sourceRaw = '${one['source'] ?? ''}'.trim().toLowerCase();
      final source = sourceRaw == 'auto' ? 'auto' : 'manual';
      if (pageIndex == null) continue;
      if (columnIndex == null || columnIndex < 0 || columnIndex > 1) continue;
      if (rowIndex < 0) continue;
      if (label.isEmpty) continue;
      final defaultTop = _defaultAnchorTopForPage(pageIndex);
      final defaultPadding = _defaultAnchorPaddingForPage(pageIndex);
      var topPt = (one['topPt'] is num)
          ? (one['topPt'] as num).toDouble()
          : defaultTop;
      var paddingTopPt = (one['paddingTopPt'] is num)
          ? (one['paddingTopPt'] as num).toDouble()
          : defaultPadding;
      // Migrate older defaults and recent transient baselines on page 2+.
      final isLegacyOld =
          (topPt - 8.0).abs() < 0.01 && (paddingTopPt - 46.0).abs() < 0.01;
      final isLegacyRecentWrong =
          pageIndex > 0 &&
          (topPt - _firstPageAnchorTopPt).abs() < 0.01 &&
          (paddingTopPt - _firstPageAnchorPaddingTopPt).abs() < 0.01;
      final isLegacyLargeGap =
          pageIndex > 0 &&
          (topPt - 18.0).abs() < 0.01 &&
          (paddingTopPt - 58.0).abs() < 0.01;
      if (isLegacyOld || isLegacyRecentWrong || isLegacyLargeGap) {
        topPt = defaultTop;
        paddingTopPt = defaultPadding;
      }
      out[_anchorKey(
        pageIndex,
        columnIndex,
        rowIndex: rowIndex,
      )] = <String, dynamic>{
        'page': pageIndex + 1,
        'columnIndex': columnIndex,
        'rowIndex': rowIndex,
        'label': label,
        'source': source,
        'topPt': topPt,
        'paddingTopPt': paddingTopPt,
      };
    }
    return out;
  }

  Map<String, Map<String, dynamic>> _readInitialColumnLabelAnchors() {
    return _parseColumnLabelAnchors(widget.initialColumnLabelAnchors);
  }

  Set<int> _labelPagesFromAnchorMap(Map<String, Map<String, dynamic>> source) {
    final maxPage = _maxEditablePageCount;
    final out = <int>{};
    for (final row in source.values) {
      final page = int.tryParse('${row['page'] ?? ''}') ?? 0;
      if (page >= 1 && page <= maxPage) out.add(page);
    }
    return out;
  }

  TextEditingController _controllerForAnchor({
    required int pageIndex,
    required int columnIndex,
    required int rowIndex,
  }) {
    final key = _anchorKey(pageIndex, columnIndex, rowIndex: rowIndex);
    final existing = _labelControllers[key];
    if (existing != null) return existing;
    final initial = '${_columnLabelAnchorMap[key]?['label'] ?? ''}'.trim();
    final controller = TextEditingController(text: initial);
    _labelControllers[key] = controller;
    return controller;
  }

  void _setAnchorLabel({
    required int pageIndex,
    required int columnIndex,
    required int rowIndex,
    required String rawLabel,
  }) {
    final key = _anchorKey(pageIndex, columnIndex, rowIndex: rowIndex);
    final label = rawLabel.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (label.isEmpty) {
      // 빈 라벨 → 해당 slot 의 라벨 제거. 서버는 refresh 시 자동 라벨 생성을 끄므로
      //   (`disableAutoLabels: true`) map 에서 그냥 빼면 된다.
      _columnLabelAnchorMap.remove(key);
      return;
    }
    final prev = _columnLabelAnchorMap[key];
    _columnLabelAnchorMap[key] = <String, dynamic>{
      'page': pageIndex + 1,
      'columnIndex': columnIndex,
      'rowIndex': rowIndex,
      'label': label,
      'source': 'manual',
      'topPt': prev?['topPt'] ?? _defaultAnchorTopForPage(pageIndex),
      'paddingTopPt':
          prev?['paddingTopPt'] ?? _defaultAnchorPaddingForPage(pageIndex),
    };
  }

  void _addDefaultAnchor({
    required int pageIndex,
    required int columnIndex,
    required int rowIndex,
  }) {
    final controller = _controllerForAnchor(
      pageIndex: pageIndex,
      columnIndex: columnIndex,
      rowIndex: rowIndex,
    );
    controller.text = widget.isGyeongsinTemplate ? '서술형' : '5지선다형';
    _setAnchorLabel(
      pageIndex: pageIndex,
      columnIndex: columnIndex,
      rowIndex: rowIndex,
      rawLabel: controller.text,
    );
    setState(() {});
  }

  List<Map<String, dynamic>> _columnLabelAnchorsPayload() {
    if (!_isTwoColumnLayout) {
      return const <Map<String, dynamic>>[];
    }
    if (_columnLabelAnchorMap.isEmpty) {
      return const <Map<String, dynamic>>[];
    }
    final maxPage = _computedPageColumnCounts.length;
    bool isValidSlot(int page, int columnIndex, int rowIndex) {
      if (!(page >= 1 &&
          page <= maxPage &&
          columnIndex >= 0 &&
          columnIndex <= 1)) {
        return false;
      }
      if (rowIndex < 0) return false;
      if (page - 1 < 0 || page - 1 >= _computedPageColumnCounts.length) {
        return false;
      }
      if (columnIndex == 1 && rowIndex == 99) return true;
      final pageCounts = _computedPageColumnCounts[page - 1];
      final rowLimit = columnIndex < pageCounts.length
          ? pageCounts[columnIndex]
          : 0;
      return rowLimit > 0 && rowIndex < rowLimit;
    }

    final items = <Map<String, dynamic>>[];
    for (final row in _columnLabelAnchorMap.values) {
      final page = int.tryParse('${row['page'] ?? 0}') ?? 0;
      final col = int.tryParse('${row['columnIndex'] ?? -1}') ?? -1;
      final rowIndex = int.tryParse('${row['rowIndex'] ?? 0}') ?? 0;
      if (!isValidSlot(page, col, rowIndex)) continue;
      items.add(<String, dynamic>{
        'columnIndex': col,
        'rowIndex': rowIndex,
        'label': row['label'],
        'source': row['source'] ?? 'manual',
        'page': page,
        'topPt': row['topPt'],
        'paddingTopPt': row['paddingTopPt'],
      });
    }
    items.sort((a, b) {
      final pageA = int.tryParse('${a['page'] ?? 0}') ?? 0;
      final pageB = int.tryParse('${b['page'] ?? 0}') ?? 0;
      if (pageA != pageB) return pageA.compareTo(pageB);
      final colA = int.tryParse('${a['columnIndex'] ?? 0}') ?? 0;
      final colB = int.tryParse('${b['columnIndex'] ?? 0}') ?? 0;
      if (colA != colB) return colA.compareTo(colB);
      final rowA = int.tryParse('${a['rowIndex'] ?? 0}') ?? 0;
      final rowB = int.tryParse('${b['rowIndex'] ?? 0}') ?? 0;
      return rowA.compareTo(rowB);
    });
    return List<Map<String, dynamic>>.unmodifiable(items);
  }

  List<List<int>> _recomputePageColumnCounts() {
    if (!_isTwoColumnLayout) return const <List<int>>[];
    final totalQuestions = math.max(0, widget.totalQuestionCount);
    if (totalQuestions <= 0) return const <List<int>>[];
    final base = _baseColumnCounts;
    var remaining = totalQuestions;
    var pageIndex = 0;
    final pages = <List<int>>[];
    while (remaining > 0) {
      final override = _pageOverrides[pageIndex];
      var left = override != null ? override[0] : base[0];
      var right = override != null ? override[1] : base[1];
      if (left < 0) left = 0;
      if (right < 0) right = 0;
      if (left + right <= 0) {
        left = 1;
        right = 0;
      }
      final assignedLeft = math.min(left, remaining);
      remaining -= assignedLeft;
      final assignedRight = math.min(right, remaining);
      remaining -= assignedRight;
      pages.add(<int>[assignedLeft, assignedRight]);
      pageIndex += 1;
    }
    return pages;
  }

  void _applyPageColumnDelta({
    required int pageIndex,
    required bool isLeft,
    required int delta,
  }) {
    if (!_isTwoColumnLayout || delta == 0) return;
    final pages = _computedPageColumnCounts.isEmpty
        ? _recomputePageColumnCounts()
        : _computedPageColumnCounts;
    if (pageIndex < 0 || pageIndex >= pages.length) return;
    final current = pages[pageIndex];
    var left = current[0];
    var right = current[1];
    if (isLeft) {
      left = math.max(0, left + delta);
    } else {
      right = math.max(0, right + delta);
    }
    if (left + right <= 0) {
      if (isLeft) {
        left = 1;
      } else {
        right = 1;
      }
    }
    _pageOverrides[pageIndex] = <int>[left, right];
    setState(() {
      _computedPageColumnCounts = _recomputePageColumnCounts();
      _syncPageScopedUiState();
    });
  }

  List<Map<String, dynamic>> _pageColumnPayload() {
    if (!_isTwoColumnLayout) {
      final total = widget.totalQuestionCount;
      final perPage = widget.maxQuestionsPerPage <= 0
          ? 4
          : widget.maxQuestionsPerPage;
      if (total <= 0 || perPage <= 0) {
        return const <Map<String, dynamic>>[];
      }
      final pageCount = (total / perPage).ceil();
      return List<Map<String, dynamic>>.generate(pageCount, (index) {
        final remaining = total - (index * perPage);
        final count = remaining < perPage ? remaining : perPage;
        return <String, dynamic>{
          'pageIndex': index + 1,
          'left': count,
          'right': 0,
        };
      });
    }
    if (_computedPageColumnCounts.isEmpty) {
      return const <Map<String, dynamic>>[];
    }
    return _computedPageColumnCounts
        .asMap()
        .entries
        .map((entry) {
          final counts = entry.value;
          return <String, dynamic>{
            'pageIndex': entry.key + 1,
            'left': counts[0],
            'right': counts[1],
          };
        })
        .where((row) => (row['left'] as int) + (row['right'] as int) > 0)
        .toList(growable: false);
  }

  List<int> _titlePageIndicesPayload() {
    final maxPage = _maxEditablePageCount;
    final pages =
        _titlePageIndexSet.where((page) => page >= 1 && page <= maxPage).toSet()
          ..add(1);
    final out = pages.toList(growable: false)..sort();
    return out;
  }

  List<Map<String, dynamic>> _titlePageHeadersPayload() {
    final pageNos = _titlePageIndicesPayload();
    final out = <Map<String, dynamic>>[];
    for (final pageNo in pageNos) {
      _ensureTitleHeaderForPage(pageNo);
      final row = _titlePageHeaderMap[pageNo] ?? const <String, String>{};
      final fallback =
          (_titlePageHeaderMap[1]?['title'] ?? _subjectController.text)
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
      final title = (row['title'] ?? '').trim().isNotEmpty
          ? (row['title'] ?? '').trim()
          : (fallback.isNotEmpty ? fallback : '수학 영역');
      final subtitle = (row['subtitle'] ?? '').trim();
      out.add(<String, dynamic>{
        'page': pageNo,
        'title': title,
        'subtitle': subtitle,
      });
    }
    return out;
  }

  Map<String, dynamic> _defaultCoverPageTexts() {
    return <String, dynamic>{
      'topTitle': '2026학년도 대학수학능력시험 문제지',
      'subjectTitle': '수학 영역',
      'handwritingPhrase': '이 많은 별빛이 내린 언덕 위에',
      'commonLabel': '공통과목',
      'commonPageRange': '1~12쪽',
      'commonItems': const <Map<String, dynamic>>[],
      'electiveLabel': '선택과목',
      'electivePageRange': '',
      'electiveItems': const <Map<String, dynamic>>[
        <String, dynamic>{'name': '확률과 통계', 'pages': '9~12쪽'},
        <String, dynamic>{'name': '미적분', 'pages': '13~16쪽'},
        <String, dynamic>{'name': '기하', 'pages': '17~20쪽'},
      ],
      'subjectGroups': const <Map<String, dynamic>>[
        <String, dynamic>{
          'label': '공통과목',
          'pageRange': '1~12쪽',
          'items': <Map<String, dynamic>>[],
        },
        <String, dynamic>{
          'label': '선택과목',
          'pageRange': '',
          'items': <Map<String, dynamic>>[
            <String, dynamic>{'name': '확률과 통계', 'pages': '9~12쪽'},
            <String, dynamic>{'name': '미적분', 'pages': '13~16쪽'},
            <String, dynamic>{'name': '기하', 'pages': '17~20쪽'},
          ],
        },
      ],
      'organization': '한국교육과정평가원',
    };
  }

  String _normalizeCoverTextValue(
    dynamic raw,
    String fallback, {
    bool allowEmpty = false,
  }) {
    var text = raw == null
        ? ''
        : '$raw'.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text == 'null') text = '';
    if (allowEmpty) return text;
    if (text.isEmpty) return fallback;
    return text;
  }

  List<Map<String, dynamic>> _normalizeCoverItemRows(
    dynamic rawItems, {
    List<Map<String, dynamic>> fallback = const <Map<String, dynamic>>[],
  }) {
    final out = <Map<String, dynamic>>[];
    if (rawItems is List) {
      for (final one in rawItems) {
        if (one is! Map) continue;
        final name = _normalizeCoverTextValue(
          one['name'],
          '',
          allowEmpty: true,
        );
        final pages = _normalizeCoverTextValue(
          one['pages'] ?? one['pageRange'],
          '',
          allowEmpty: true,
        );
        if (name.isEmpty && pages.isEmpty) continue;
        out.add(<String, dynamic>{'name': name, 'pages': pages});
      }
    }
    if (out.isNotEmpty) return out;
    return fallback
        .map(
          (row) => <String, dynamic>{
            'name': _normalizeCoverTextValue(row['name'], '', allowEmpty: true),
            'pages': _normalizeCoverTextValue(
              row['pages'],
              '',
              allowEmpty: true,
            ),
          },
        )
        .where((row) => ('${row['name']}${row['pages']}').trim().isNotEmpty)
        .toList(growable: false);
  }

  List<Map<String, dynamic>> _normalizeCoverSubjectGroups({
    required Map src,
    required Map<String, dynamic> defaults,
    required bool explicitGroupsPresent,
  }) {
    final fallbackGroups = (defaults['subjectGroups'] as List<dynamic>)
        .whereType<Map>()
        .map((row) => row.map((key, value) => MapEntry('$key', value)))
        .toList(growable: false);

    if (explicitGroupsPresent) {
      final rawGroups = src['subjectGroups'];
      if (rawGroups is! List) {
        return const <Map<String, dynamic>>[];
      }
      final out = <Map<String, dynamic>>[];
      for (var i = 0; i < rawGroups.length; i += 1) {
        final one = rawGroups[i];
        if (one is! Map) continue;
        final fallbackLabel =
            '${(i < fallbackGroups.length ? fallbackGroups[i]['label'] : null) ?? '대분류 ${i + 1}'}';
        final label = _normalizeCoverTextValue(
          one['label'],
          fallbackLabel,
          allowEmpty: true,
        );
        final pageRange = _normalizeCoverTextValue(
          one['pageRange'] ?? one['pages'],
          '',
          allowEmpty: true,
        );
        final items = _normalizeCoverItemRows(
          one['items'],
          fallback: const <Map<String, dynamic>>[],
        );
        out.add(<String, dynamic>{
          'label': label.isNotEmpty ? label : fallbackLabel,
          'pageRange': pageRange,
          'items': items,
        });
      }
      return out;
    }

    final commonGroup = <String, dynamic>{
      'label': _normalizeCoverTextValue(
        src['commonLabel'],
        '${defaults['commonLabel'] ?? '공통과목'}',
      ),
      'pageRange': _normalizeCoverTextValue(
        src['commonPageRange'] ?? src['commonPages'],
        '${defaults['commonPageRange'] ?? '1~12쪽'}',
        allowEmpty: true,
      ),
      'items': _normalizeCoverItemRows(
        src['commonItems'],
        fallback: (defaults['commonItems'] as List<dynamic>)
            .whereType<Map>()
            .map((row) => row.map((key, value) => MapEntry('$key', value)))
            .toList(growable: false),
      ),
    };
    final electiveGroup = <String, dynamic>{
      'label': _normalizeCoverTextValue(
        src['electiveLabel'],
        '${defaults['electiveLabel'] ?? '선택과목'}',
      ),
      'pageRange': _normalizeCoverTextValue(
        src['electivePageRange'] ?? src['electivePages'],
        '${defaults['electivePageRange'] ?? ''}',
        allowEmpty: true,
      ),
      'items': _normalizeCoverItemRows(
        src['electiveItems'],
        fallback: (defaults['electiveItems'] as List<dynamic>)
            .whereType<Map>()
            .map((row) => row.map((key, value) => MapEntry('$key', value)))
            .toList(growable: false),
      ),
    };
    return <Map<String, dynamic>>[commonGroup, electiveGroup];
  }

  Map<String, dynamic> _normalizeCoverPageTexts(dynamic source) {
    final defaults = _defaultCoverPageTexts();
    final src = source is Map ? source : const <String, dynamic>{};
    final explicitGroupsPresent = src['subjectGroups'] is List;
    final subjectGroups = _normalizeCoverSubjectGroups(
      src: src,
      defaults: defaults,
      explicitGroupsPresent: explicitGroupsPresent,
    );
    final fallbackGroups = (defaults['subjectGroups'] as List<dynamic>)
        .whereType<Map>()
        .map((row) => row.map((key, value) => MapEntry('$key', value)))
        .toList(growable: false);
    final commonGroup = subjectGroups.isNotEmpty
        ? subjectGroups.first
        : (fallbackGroups.isNotEmpty
              ? fallbackGroups.first
              : const <String, dynamic>{});
    final electiveGroup = subjectGroups.length > 1
        ? subjectGroups[1]
        : (fallbackGroups.length > 1
              ? fallbackGroups[1]
              : const <String, dynamic>{});
    final commonLabel =
        '${commonGroup['label'] ?? defaults['commonLabel'] ?? '공통과목'}';
    final commonPageRange = _normalizeCoverTextValue(
      commonGroup['pageRange'],
      '${defaults['commonPageRange'] ?? '1~12쪽'}',
      allowEmpty: true,
    );
    final commonItems = _normalizeCoverItemRows(
      commonGroup['items'],
      fallback: const <Map<String, dynamic>>[],
    );
    final electiveLabel =
        '${electiveGroup['label'] ?? defaults['electiveLabel'] ?? '선택과목'}';
    final electivePageRange = _normalizeCoverTextValue(
      electiveGroup['pageRange'],
      '${defaults['electivePageRange'] ?? ''}',
      allowEmpty: true,
    );
    final electiveItems = _normalizeCoverItemRows(
      electiveGroup['items'],
      fallback: const <Map<String, dynamic>>[],
    );
    return <String, dynamic>{
      'topTitle': _normalizeCoverTextValue(
        src['topTitle'],
        '${defaults['topTitle'] ?? ''}',
      ),
      'subjectTitle': _normalizeCoverTextValue(
        src['subjectTitle'],
        '${defaults['subjectTitle'] ?? ''}',
      ),
      'handwritingPhrase': _normalizeCoverTextValue(
        src['handwritingPhrase'],
        '${defaults['handwritingPhrase'] ?? ''}',
      ),
      'commonLabel': commonLabel,
      'commonPageRange': commonPageRange.isNotEmpty
          ? commonPageRange
          : '${defaults['commonPageRange'] ?? ''}',
      'commonItems': commonItems,
      'electiveLabel': electiveLabel,
      'electivePageRange': electivePageRange,
      'electiveItems': electiveItems,
      'subjectGroups': subjectGroups,
      'organization': _normalizeCoverTextValue(
        src['organization'],
        '${defaults['organization'] ?? ''}',
      ),
      'examDate': _normalizeCoverTextValue(
        src['examDate'],
        _koreaTodayExamDate(),
        allowEmpty: true,
      ),
      'coverExamTitle': _normalizeCoverTextValue(
        src['coverExamTitle'],
        '2026학년도 3학년 2학기 기말시험',
        allowEmpty: true,
      ),
      'headerExamTitle': _normalizeCoverTextValue(
        src['headerExamTitle'],
        '제 3 학년 2 학기 기말시험',
        allowEmpty: true,
      ),
      'subjectName': _normalizeCoverTextValue(
        src['subjectName'],
        '수학',
        allowEmpty: true,
      ),
      'objectiveCount': _normalizeCoverTextValue(
        src['objectiveCount'],
        '',
        allowEmpty: true,
      ),
      'subjectiveCount': _normalizeCoverTextValue(
        src['subjectiveCount'],
        '',
        allowEmpty: true,
      ),
      'essayCount': _normalizeCoverTextValue(
        src['essayCount'],
        '',
        allowEmpty: true,
      ),
      'periodLabel': _normalizeCoverTextValue(
        src['periodLabel'],
        widget.isDaeryunTemplate
            ? '제 2 교시'
            : (widget.isSoseonTemplate
                  ? '3교시'
                  : ((widget.isJeonghwaTemplate || widget.isHwanggeumTemplate)
                        ? '1교시'
                        : (widget.isOseongTemplate ? '제 1 교시' : '제 1교시'))),
        allowEmpty: true,
      ),
      'subjectCode': _normalizeCoverTextValue(
        src['subjectCode'],
        (widget.isDaeryunTemplate ||
                widget.isSoseonTemplate ||
                widget.isOseongTemplate ||
                widget.isHwanggeumTemplate)
            ? '04'
            : '05',
        allowEmpty: true,
      ),
      'sheetTypeLabel': _normalizeCoverTextValue(
        src['sheetTypeLabel'] ?? src['sheetType'],
        '답안지 D형',
        allowEmpty: true,
      ),
      'objectiveScore': _normalizeCoverTextValue(
        src['objectiveScore'],
        '',
        allowEmpty: true,
      ),
      'essayScore': _normalizeCoverTextValue(
        src['essayScore'],
        '',
        allowEmpty: true,
      ),
      'totalPageCount': _normalizeCoverTextValue(
        src['totalPageCount'],
        '',
        allowEmpty: true,
      ),
      'footerLabel': _normalizeCoverTextValue(
        src['footerLabel'],
        '',
        allowEmpty: true,
      ),
      'pageStartNumber': _normalizeCoverTextValue(
        src['pageStartNumber'],
        '',
        allowEmpty: true,
      ),
      'includeCoverBlankPage': _readCoverBlankPageFlag(
        src['includeCoverBlankPage'],
      ),
    };
  }

  bool get _defaultIncludeCoverBlankPage {
    if (widget.isGyeongsinTemplate) return true;
    if (widget.isNeunginTemplate ||
        widget.isDaeryunTemplate ||
        widget.isDongdoTemplate ||
        widget.isSoseonTemplate ||
        widget.isOseongTemplate ||
        widget.isJeonghwaTemplate ||
        widget.isHwanggeumTemplate ||
        widget.isAssignmentTemplate) {
      return false;
    }
    return true;
  }

  bool _readCoverBlankPageFlag(dynamic raw) {
    if (raw is bool) return raw;
    if (raw is num) return raw != 0;
    final text = '${raw ?? ''}'.trim().toLowerCase();
    if (text == 'true' || text == '1' || text == 'yes' || text == 'on') {
      return true;
    }
    if (text == 'false' || text == '0' || text == 'no' || text == 'off') {
      return false;
    }
    return _defaultIncludeCoverBlankPage;
  }

  int get _coverPageSheetCount {
    final raw = widget.initialCoverPageTexts['coverPageCount'];
    final parsed = raw is int ? raw : int.tryParse('${raw ?? ''}');
    return (parsed != null && parsed >= 1) ? parsed : 1;
  }

  void _disposeCoverGroupControllers() {
    for (final controller in _coverGroupLabelControllers) {
      controller.dispose();
    }
    for (final controller in _coverGroupPageRangeControllers) {
      controller.dispose();
    }
    for (final list in _coverGroupItemNameControllers) {
      for (final controller in list) {
        controller.dispose();
      }
    }
    for (final list in _coverGroupItemPageControllers) {
      for (final controller in list) {
        controller.dispose();
      }
    }
    _coverGroupLabelControllers.clear();
    _coverGroupPageRangeControllers.clear();
    _coverGroupItemNameControllers.clear();
    _coverGroupItemPageControllers.clear();
  }

  void _appendCoverSubjectGroupControllers({
    required String label,
    required String pageRange,
    required List<Map<String, dynamic>> items,
  }) {
    _coverGroupLabelControllers.add(TextEditingController(text: label));
    _coverGroupPageRangeControllers.add(TextEditingController(text: pageRange));
    final itemNameControllers = <TextEditingController>[];
    final itemPageControllers = <TextEditingController>[];
    for (final row in items) {
      itemNameControllers.add(
        TextEditingController(text: '${row['name'] ?? ''}'),
      );
      itemPageControllers.add(
        TextEditingController(text: '${row['pages'] ?? ''}'),
      );
    }
    _coverGroupItemNameControllers.add(itemNameControllers);
    _coverGroupItemPageControllers.add(itemPageControllers);
  }

  void _setCoverSubjectGroupsFromNormalized(List<Map<String, dynamic>> groups) {
    _disposeCoverGroupControllers();
    for (var i = 0; i < groups.length; i += 1) {
      final group = groups[i];
      _appendCoverSubjectGroupControllers(
        label: _normalizeCoverTextValue(group['label'], '대분류 ${i + 1}'),
        pageRange: _normalizeCoverTextValue(
          group['pageRange'],
          '',
          allowEmpty: true,
        ),
        items: _normalizeCoverItemRows(
          group['items'],
          fallback: const <Map<String, dynamic>>[],
        ),
      );
    }
  }

  void _addCoverSubjectGroup({
    String label = '',
    String pageRange = '',
    List<Map<String, dynamic>> items = const <Map<String, dynamic>>[],
  }) {
    setState(() {
      _appendCoverSubjectGroupControllers(
        label: label.trim().isNotEmpty
            ? label.trim()
            : '대분류 ${_coverGroupLabelControllers.length + 1}',
        pageRange: pageRange.trim(),
        items: items,
      );
    });
  }

  void _removeCoverSubjectGroup(int groupIndex) {
    setState(() {
      if (groupIndex < 0 || groupIndex >= _coverGroupLabelControllers.length) {
        return;
      }
      if (groupIndex >= _coverGroupPageRangeControllers.length ||
          groupIndex >= _coverGroupItemNameControllers.length ||
          groupIndex >= _coverGroupItemPageControllers.length) {
        return;
      }
      _coverGroupLabelControllers.removeAt(groupIndex).dispose();
      _coverGroupPageRangeControllers.removeAt(groupIndex).dispose();
      final names = _coverGroupItemNameControllers.removeAt(groupIndex);
      final pages = _coverGroupItemPageControllers.removeAt(groupIndex);
      for (final controller in names) {
        controller.dispose();
      }
      for (final controller in pages) {
        controller.dispose();
      }
    });
  }

  void _addCoverSubjectItem({required int groupIndex}) {
    setState(() {
      if (groupIndex < 0 ||
          groupIndex >= _coverGroupItemNameControllers.length ||
          groupIndex >= _coverGroupItemPageControllers.length) {
        return;
      }
      _coverGroupItemNameControllers[groupIndex].add(TextEditingController());
      _coverGroupItemPageControllers[groupIndex].add(TextEditingController());
    });
  }

  void _removeCoverSubjectItem({
    required int groupIndex,
    required int itemIndex,
  }) {
    setState(() {
      if (groupIndex < 0 ||
          groupIndex >= _coverGroupItemNameControllers.length ||
          groupIndex >= _coverGroupItemPageControllers.length) {
        return;
      }
      final nameControllers = _coverGroupItemNameControllers[groupIndex];
      final pageControllers = _coverGroupItemPageControllers[groupIndex];
      if (itemIndex < 0 ||
          itemIndex >= nameControllers.length ||
          itemIndex >= pageControllers.length) {
        return;
      }
      nameControllers.removeAt(itemIndex).dispose();
      pageControllers.removeAt(itemIndex).dispose();
    });
  }

  void _syncCoverPageTextControllers(Map<String, dynamic> config) {
    final normalized = _normalizeCoverPageTexts(config);
    _coverTopTitleController.text = '${normalized['topTitle'] ?? ''}';
    _coverSubjectTitleController.text = '${normalized['subjectTitle'] ?? ''}';
    _coverPhraseController.text = '${normalized['handwritingPhrase'] ?? ''}';
    _coverOrganizationController.text = '${normalized['organization'] ?? ''}';
    final examDate = '${normalized['examDate'] ?? ''}'.trim();
    _gyeongsinExamDateController.text = examDate.isNotEmpty
        ? examDate
        : _koreaTodayExamDate();
    final periodLabel = '${normalized['periodLabel'] ?? ''}'.trim();
    _gyeongsinPeriodLabelController.text = periodLabel.isNotEmpty
        ? periodLabel
        : (widget.isDaeryunTemplate
              ? '제 2 교시'
              : (widget.isSoseonTemplate
                    ? '3교시'
                    : ((widget.isJeonghwaTemplate || widget.isHwanggeumTemplate)
                          ? '1교시'
                          : (widget.isOseongTemplate ? '제 1 교시' : '제 1교시'))));
    final subjectCode = '${normalized['subjectCode'] ?? ''}'.trim();
    _gyeongsinSubjectCodeController.text = subjectCode.isNotEmpty
        ? subjectCode
        : ((widget.isDaeryunTemplate ||
                  widget.isSoseonTemplate ||
                  widget.isOseongTemplate ||
                  widget.isHwanggeumTemplate)
              ? '04'
              : '05');
    final sheetTypeLabel = '${normalized['sheetTypeLabel'] ?? ''}'.trim();
    _gyeongsinSheetTypeController.text = sheetTypeLabel.isNotEmpty
        ? sheetTypeLabel
        : '답안지 D형';
    final coverExamTitle = '${normalized['coverExamTitle'] ?? ''}'.trim();
    _gyeongsinCoverExamTitleController.text = coverExamTitle.isNotEmpty
        ? coverExamTitle
        : (widget.isDaeryunTemplate
              ? '2026학년도 2학기 중간시험 2학년 문제지'
              : (widget.isDongdoTemplate
                    ? '2026학년도 수학과 제3학년 2학기 기말고사'
                    : (widget.isSoseonTemplate
                          ? '2026학년도 2학기 3학년 기말시험 문제지'
                          : (widget.isOseongTemplate
                                ? '2026학년도 2학기 기말시험'
                                : (widget.isJeonghwaTemplate
                                      ? '2026학년도 2학년 2학기 중간시험'
                                      : (widget.isHwanggeumTemplate
                                            ? '2026학년도 1학기 기말시험 3학년'
                                            : '2026학년도 3학년 2학기 기말시험'))))));
    final headerExamTitle = '${normalized['headerExamTitle'] ?? ''}'.trim();
    _gyeongsinHeaderExamTitleController.text = headerExamTitle.isNotEmpty
        ? headerExamTitle
        : (widget.isDaeryunTemplate
              ? '2026학년도 2학기 중간시험 2학년 문제지'
              : (widget.isDongdoTemplate
                    ? '2026학년도 수학과 제3학년 2학기 기말고사'
                    : (widget.isSoseonTemplate
                          ? '3학년 2학기 기말시험'
                          : (widget.isOseongTemplate
                                ? '2026학년도 오성중학교 2학기 기말시험 문제지'
                                : '제 3 학년 2 학기 기말시험'))));
    final subjectName = '${normalized['subjectName'] ?? ''}'.trim();
    _gyeongsinSubjectNameController.text = subjectName.isNotEmpty
        ? subjectName
        : '수학';
    _gyeongsinObjectiveCountController.text =
        '${normalized['objectiveCount'] ?? ''}';
    _gyeongsinSubjectiveCountController.text =
        '${normalized['subjectiveCount'] ?? ''}';
    _gyeongsinEssayCountController.text = '${normalized['essayCount'] ?? ''}';
    _gyeongsinObjectiveScoreController.text =
        '${normalized['objectiveScore'] ?? ''}';
    _gyeongsinEssayScoreController.text = '${normalized['essayScore'] ?? ''}';
    _gyeongsinTotalPageCountController.text =
        '${normalized['totalPageCount'] ?? ''}';
    _gyeongsinFooterLabelController.text = '${normalized['footerLabel'] ?? ''}';
    _gyeongsinPageStartController.text =
        '${normalized['pageStartNumber'] ?? ''}';
    if (normalized.containsKey('includeCoverBlankPage')) {
      _includeCoverBlankPage = _readCoverBlankPageFlag(
        normalized['includeCoverBlankPage'],
      );
    }
    final groups = (normalized['subjectGroups'] as List<dynamic>)
        .whereType<Map>()
        .map((row) => row.map((key, value) => MapEntry('$key', value)))
        .toList(growable: false);
    _setCoverSubjectGroupsFromNormalized(groups);
  }

  Map<String, dynamic> _coverPageTextsPayload() {
    final defaults = _defaultCoverPageTexts();
    List<Map<String, dynamic>> readRows(
      List<TextEditingController> names,
      List<TextEditingController> pages,
    ) {
      final out = <Map<String, dynamic>>[];
      final maxLen = math.min(names.length, pages.length);
      for (var i = 0; i < maxLen; i += 1) {
        final name = _normalizeCoverTextValue(
          names[i].text,
          '',
          allowEmpty: true,
        );
        final page = _normalizeCoverTextValue(
          pages[i].text,
          '',
          allowEmpty: true,
        );
        if (name.isEmpty && page.isEmpty) continue;
        out.add(<String, dynamic>{'name': name, 'pages': page});
      }
      return out;
    }

    final groupCount = [
      _coverGroupLabelControllers.length,
      _coverGroupPageRangeControllers.length,
      _coverGroupItemNameControllers.length,
      _coverGroupItemPageControllers.length,
    ].reduce(math.min);
    final subjectGroups = <Map<String, dynamic>>[];
    for (var i = 0; i < groupCount; i += 1) {
      final label = _normalizeCoverTextValue(
        _coverGroupLabelControllers[i].text,
        '대분류 ${i + 1}',
      );
      final pageRange = _normalizeCoverTextValue(
        _coverGroupPageRangeControllers[i].text,
        '',
        allowEmpty: true,
      );
      final items = readRows(
        _coverGroupItemNameControllers[i],
        _coverGroupItemPageControllers[i],
      );
      subjectGroups.add(<String, dynamic>{
        'label': label,
        'pageRange': pageRange,
        'items': items,
      });
    }
    final defaultGroups = (defaults['subjectGroups'] as List<dynamic>)
        .whereType<Map>()
        .map((row) => row.map((key, value) => MapEntry('$key', value)))
        .toList(growable: false);
    final commonGroup = subjectGroups.isNotEmpty
        ? subjectGroups.first
        : (defaultGroups.isNotEmpty
              ? defaultGroups.first
              : const <String, dynamic>{});
    final electiveGroup = subjectGroups.length > 1
        ? subjectGroups[1]
        : (defaultGroups.length > 1
              ? defaultGroups[1]
              : const <String, dynamic>{});
    final commonLabel =
        '${commonGroup['label'] ?? defaults['commonLabel'] ?? '공통과목'}';
    final commonPageRange = _normalizeCoverTextValue(
      commonGroup['pageRange'],
      '${defaults['commonPageRange'] ?? ''}',
      allowEmpty: true,
    );
    final commonItems = (commonGroup['items'] is List)
        ? (commonGroup['items'] as List<dynamic>)
              .whereType<Map>()
              .map((row) => row.map((key, value) => MapEntry('$key', value)))
              .toList(growable: false)
        : const <Map<String, dynamic>>[];
    final electiveLabel =
        '${electiveGroup['label'] ?? defaults['electiveLabel'] ?? '선택과목'}';
    final electivePageRange = _normalizeCoverTextValue(
      electiveGroup['pageRange'],
      '${defaults['electivePageRange'] ?? ''}',
      allowEmpty: true,
    );
    final electiveItems = (electiveGroup['items'] is List)
        ? (electiveGroup['items'] as List<dynamic>)
              .whereType<Map>()
              .map((row) => row.map((key, value) => MapEntry('$key', value)))
              .toList(growable: false)
        : const <Map<String, dynamic>>[];
    return <String, dynamic>{
      'topTitle': _normalizeCoverTextValue(
        _coverTopTitleController.text,
        '${defaults['topTitle'] ?? ''}',
      ),
      'subjectTitle': _normalizeCoverTextValue(
        _coverSubjectTitleController.text,
        '${defaults['subjectTitle'] ?? ''}',
      ),
      'handwritingPhrase': _normalizeCoverTextValue(
        _coverPhraseController.text,
        '${defaults['handwritingPhrase'] ?? ''}',
      ),
      'commonLabel': commonLabel,
      'commonPageRange': commonPageRange.isNotEmpty
          ? commonPageRange
          : '${defaults['commonPageRange'] ?? ''}',
      'commonItems': commonItems,
      'electiveLabel': electiveLabel,
      'electivePageRange': electivePageRange,
      'electiveItems': electiveItems,
      'subjectGroups': subjectGroups,
      'organization': _normalizeCoverTextValue(
        _coverOrganizationController.text,
        '${defaults['organization'] ?? ''}',
      ),
      'includeCoverBlankPage': _includeCoverBlankPage,
      if (widget.isGyeongsinTemplate ||
          widget.isNeunginTemplate ||
          widget.isDaeryunTemplate ||
          widget.isDongdoTemplate ||
          widget.isSoseonTemplate ||
          widget.isOseongTemplate ||
          widget.isJeonghwaTemplate ||
          widget.isHwanggeumTemplate) ...<String, dynamic>{
        'examDate': _normalizeCoverTextValue(
          _gyeongsinExamDateController.text,
          _koreaTodayExamDate(),
        ),
        'periodLabel': _normalizeCoverTextValue(
          _gyeongsinPeriodLabelController.text,
          widget.isDaeryunTemplate
              ? '제 2 교시'
              : (widget.isSoseonTemplate
                    ? '3교시'
                    : ((widget.isJeonghwaTemplate || widget.isHwanggeumTemplate)
                          ? '1교시'
                          : (widget.isOseongTemplate ? '제 1 교시' : '제 1교시'))),
        ),
        'subjectCode': _normalizeCoverTextValue(
          _gyeongsinSubjectCodeController.text,
          (widget.isDaeryunTemplate ||
                  widget.isSoseonTemplate ||
                  widget.isOseongTemplate ||
                  widget.isHwanggeumTemplate)
              ? '04'
              : '05',
        ),
        'sheetTypeLabel': _normalizeCoverTextValue(
          _gyeongsinSheetTypeController.text,
          '답안지 D형',
        ),
        'coverExamTitle': _normalizeCoverTextValue(
          _gyeongsinCoverExamTitleController.text,
          widget.isDaeryunTemplate
              ? '2026학년도 2학기 중간시험 2학년 문제지'
              : (widget.isDongdoTemplate
                    ? '2026학년도 수학과 제3학년 2학기 기말고사'
                    : (widget.isSoseonTemplate
                          ? '2026학년도 2학기 3학년 기말시험 문제지'
                          : (widget.isOseongTemplate
                                ? '2026학년도 2학기 기말시험'
                                : (widget.isJeonghwaTemplate
                                      ? '2026학년도 2학년 2학기 중간시험'
                                      : (widget.isHwanggeumTemplate
                                            ? '2026학년도 1학기 기말시험 3학년'
                                            : '2026학년도 3학년 2학기 기말시험'))))),
        ),
        'headerExamTitle': _normalizeCoverTextValue(
          (widget.isDaeryunTemplate || widget.isDongdoTemplate)
              ? _gyeongsinCoverExamTitleController.text
              : _gyeongsinHeaderExamTitleController.text,
          widget.isDaeryunTemplate
              ? '2026학년도 2학기 중간시험 2학년 문제지'
              : (widget.isDongdoTemplate
                    ? '2026학년도 수학과 제3학년 2학기 기말고사'
                    : (widget.isSoseonTemplate
                          ? '3학년 2학기 기말시험'
                          : (widget.isOseongTemplate
                                ? '2026학년도 오성중학교 2학기 기말시험 문제지'
                                : '제 3 학년 2 학기 기말시험'))),
        ),
        'subjectName': _normalizeCoverTextValue(
          _gyeongsinSubjectNameController.text,
          '수학',
        ),
        'objectiveCount': _normalizeCoverTextValue(
          _gyeongsinObjectiveCountController.text,
          '',
          allowEmpty: true,
        ),
        'subjectiveCount': _normalizeCoverTextValue(
          _gyeongsinSubjectiveCountController.text,
          '',
          allowEmpty: true,
        ),
        'essayCount': _normalizeCoverTextValue(
          _gyeongsinEssayCountController.text,
          '',
          allowEmpty: true,
        ),
        'objectiveScore': _normalizeCoverTextValue(
          _gyeongsinObjectiveScoreController.text,
          '',
          allowEmpty: true,
        ),
        'essayScore': _normalizeCoverTextValue(
          _gyeongsinEssayScoreController.text,
          '',
          allowEmpty: true,
        ),
        'totalPageCount': _normalizeCoverTextValue(
          _gyeongsinTotalPageCountController.text,
          '',
          allowEmpty: true,
        ),
        'footerLabel': _normalizeCoverTextValue(
          _gyeongsinFooterLabelController.text,
          '',
          allowEmpty: true,
        ),
        'pageStartNumber': _normalizeCoverTextValue(
          _gyeongsinPageStartController.text,
          '',
          allowEmpty: true,
        ),
      },
    };
  }

  ProblemBankPreviewRefreshRequest _buildRequestPayload() {
    return ProblemBankPreviewRefreshRequest(
      subjectTitleText: _subjectController.text.trim(),
      titlePageTopText: _titlePageTopTextController.text.trim(),
      titlePageGoalText: _titlePageGoalTextController.text.trim(),
      timeLimitText: _timeLimitController.text.trim(),
      pageColumnQuestionCounts: _pageColumnPayload(),
      columnLabelAnchors: _columnLabelAnchorsPayload(),
      titlePageIndices: _titlePageIndicesPayload(),
      titlePageHeaders: _titlePageHeadersPayload(),
      coverPageTexts: _coverPageTextsPayload(),
      includeAcademyLogo: _includeAcademyLogo,
      includeCoverPage: _includeCoverPage,
      includeCoverBlankPage: _includeCoverBlankPage,
      includeAnswerSheet: _includeAnswerSheet,
      includeExplanation: _includeExplanation,
      includeQuestionScore: _includeQuestionScore,
      questionScoreByQuestionId: _questionScorePayload(),
      presetDisplayName: '',
      mathEngine: _mathEngine,
      // '새로고침' 및 'PDF 생성' 은 첫 렌더 이후의 재렌더 경로이므로
      //   서버의 자동 라벨(객관식/유형 전환) 생성을 끄고, UI 에 있는 라벨만 그대로 사용한다.
      //   최초 렌더(대화상자 오픈)에는 이 payload 가 쓰이지 않으므로 auto 생성이 정상 동작.
      disableAutoLabels: true,
    );
  }

  dynamic _stableJsonValue(dynamic value) {
    if (value is Map) {
      final keys = value.keys.map((e) => '$e').toList(growable: false)..sort();
      return <String, dynamic>{
        for (final key in keys) key: _stableJsonValue(value[key]),
      };
    }
    if (value is List) {
      return value.map(_stableJsonValue).toList(growable: false);
    }
    return value;
  }

  String _signatureForPayload(ProblemBankPreviewRefreshRequest payload) {
    return jsonEncode(
      _stableJsonValue(<String, dynamic>{
        'subjectTitleText': payload.subjectTitleText,
        'titlePageTopText': payload.titlePageTopText,
        'timeLimitText': payload.timeLimitText,
        'pageColumnQuestionCounts': payload.pageColumnQuestionCounts,
        'columnLabelAnchors': payload.columnLabelAnchors,
        'titlePageIndices': payload.titlePageIndices,
        'titlePageHeaders': payload.titlePageHeaders,
        'coverPageTexts': payload.coverPageTexts,
        'includeAcademyLogo': payload.includeAcademyLogo,
        'includeCoverPage': payload.includeCoverPage,
        'includeCoverBlankPage': payload.includeCoverBlankPage,
        'includeAnswerSheet': payload.includeAnswerSheet,
        'includeExplanation': payload.includeExplanation,
        'includeQuestionScore': payload.includeQuestionScore,
        'questionScoreByQuestionId': payload.questionScoreByQuestionId,
        'mathEngine': payload.mathEngine,
      }),
    );
  }

  String _currentStateSignature() {
    return _signatureForPayload(_buildRequestPayload());
  }

  bool get _hasUnsavedPresetChanges {
    if (_editingPresetId.trim().isEmpty) return false;
    return _currentStateSignature() != _initialStateSignature;
  }

  void _markCurrentStateSaved() {
    _initialStateSignature = _currentStateSignature();
  }

  Future<bool> _confirmDiscardUnsavedChanges() async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: kDlgBg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: _panelBorder),
          ),
          title: const Text(
            '저장하지 않은 수정 내용',
            style: TextStyle(color: _textPrimary, fontWeight: FontWeight.w900),
          ),
          content: const Text(
            '저장된 프리셋을 수정한 내용이 있습니다. 저장하지 않고 닫을까요?',
            style: TextStyle(
              color: _textMuted,
              height: 1.35,
              fontWeight: FontWeight.w600,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              style: TextButton.styleFrom(foregroundColor: _textMuted),
              child: const Text('계속 편집'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF7A3A3A),
                foregroundColor: Colors.white,
              ),
              child: const Text('저장하지 않고 닫기'),
            ),
          ],
        );
      },
    );
    return result == true;
  }

  Future<void> _attemptClose() async {
    if (_isRefreshing ||
        _isGeneratingPdf ||
        _isSavingSettings ||
        _isCreatingAssignment) {
      return;
    }
    if (_hasUnsavedPresetChanges) {
      final discard = await _confirmDiscardUnsavedChanges();
      if (!discard || !mounted) return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  PdfPageLayout _layoutTwoPageVertical(
    List<PdfPage> pages,
    PdfViewerParams params,
  ) {
    if (pages.isEmpty) {
      return PdfPageLayout(
        pageLayouts: const <Rect>[],
        documentSize: Size.zero,
      );
    }
    const colGap = 20.0;
    const rowGap = 24.0;
    final rowWidths = <double>[];
    for (var i = 0; i < pages.length; i += 2) {
      final left = pages[i];
      final right = (i + 1) < pages.length ? pages[i + 1] : null;
      final width = right == null
          ? left.width
          : left.width + colGap + right.width;
      rowWidths.add(width);
    }
    final maxRowWidth = rowWidths.fold<double>(0, (acc, w) => math.max(acc, w));
    final totalWidth = maxRowWidth + params.margin * 2;
    final layouts = <Rect>[];
    var y = params.margin;
    for (var i = 0; i < pages.length; i += 2) {
      final left = pages[i];
      final right = (i + 1) < pages.length ? pages[i + 1] : null;
      final rowWidth = right == null
          ? left.width
          : left.width + colGap + right.width;
      final startX = (totalWidth - rowWidth) / 2;
      layouts.add(Rect.fromLTWH(startX, y, left.width, left.height));
      if (right != null) {
        layouts.add(
          Rect.fromLTWH(
            startX + left.width + colGap,
            y,
            right.width,
            right.height,
          ),
        );
      }
      final rowHeight = math.max(left.height, right?.height ?? 0);
      y += rowHeight + rowGap;
    }
    return PdfPageLayout(
      pageLayouts: layouts,
      documentSize: Size(totalWidth, y + params.margin),
    );
  }

  Future<void> _zoomByFactor(double factor) async {
    if (!_viewerController.isReady) return;
    final current = _viewerController.currentZoom;
    final target = (current * factor).clamp(_minScale, _maxScale).toDouble();
    final center = _viewerController.centerPosition;
    final matrix = _viewerController.calcMatrixFor(center, zoom: target);
    await _viewerController.goTo(
      matrix,
      duration: const Duration(milliseconds: 110),
    );
    if (mounted) setState(() {});
  }

  Future<void> _resetZoomToFit() async {
    if (!_viewerController.isReady) return;
    final target = (_fitZoom ?? 1.0).clamp(_minScale, _maxScale).toDouble();
    final center = _viewerController.centerPosition;
    final matrix = _viewerController.calcMatrixFor(center, zoom: target);
    await _viewerController.goTo(
      matrix,
      duration: const Duration(milliseconds: 120),
    );
    if (mounted) setState(() {});
  }

  Future<void> _printCurrentPdf() async {
    if (_isPrintingPdf) return;
    final uri = Uri.tryParse(_currentPdfUrl.trim());
    if (uri == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('인쇄할 PDF URL이 없습니다.')));
      return;
    }
    setState(() {
      _isPrintingPdf = true;
    });
    try {
      final response = await http.get(uri);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('PDF 다운로드 실패(${response.statusCode})');
      }
      if (response.bodyBytes.isEmpty) {
        throw Exception('PDF 데이터가 비어 있습니다.');
      }
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}${Platform.pathSeparator}server_pdf_preview_${DateTime.now().millisecondsSinceEpoch}.pdf',
      );
      await file.writeAsBytes(response.bodyBytes, flush: true);
      final printRequested = widget.onPrintRequested;
      if (printRequested == null) {
        throw StateError('PDF 인쇄 콜백이 설정되지 않았습니다.');
      }
      final directPrinted = await printRequested(file.path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            directPrinted ? '인쇄 요청을 보냈습니다.' : 'PDF를 열었습니다. 인쇄를 진행해 주세요.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('인쇄 준비 실패: $e')));
    } finally {
      if (mounted) {
        setState(() {
          _isPrintingPdf = false;
        });
      }
    }
  }

  Future<void> _refreshPreview() async {
    final callback = widget.onRefreshRequested;
    if (callback == null || _isRefreshing) return;
    final requestedEngine = _mathEngine;
    setState(() {
      _isRefreshing = true;
      _previewFailureMessage = null;
    });
    try {
      final refreshed = await callback(_buildRequestPayload());
      if (!mounted) return;
      if (refreshed == null || refreshed.pdfUrl.trim().isEmpty) {
        setState(() {
          _currentPdfUrl = '';
          _fitZoom = null;
          _pageNumber = 1;
          _pageCount = 0;
          _viewerRevision += 1;
          _previewFailureMessage = requestedEngine == 'xelatex'
              ? 'XeLaTeX 렌더링에 실패했습니다. 오류 메시지를 확인해주세요.'
              : '미리보기 생성에 실패했습니다.';
        });
        return;
      }
      final refreshedEngine = refreshed.mathEngine.trim().toLowerCase();
      if (refreshedEngine.isNotEmpty && refreshedEngine != requestedEngine) {
        setState(() {
          _currentPdfUrl = '';
          _fitZoom = null;
          _pageNumber = 1;
          _pageCount = 0;
          _viewerRevision += 1;
          _previewFailureMessage =
              '렌더 엔진 응답 불일치($requestedEngine -> $refreshedEngine)로 미리보기를 표시하지 않습니다.';
        });
        return;
      }
      setState(() {
        _currentPdfUrl = refreshed.pdfUrl.trim();
        _fitZoom = null;
        _pageNumber = 1;
        _pageCount = 0;
        _viewerRevision += 1;
        _includeAcademyLogo = refreshed.includeAcademyLogo;
        _includeCoverPage = refreshed.includeCoverPage;
        if (refreshed.includeCoverBlankPage != null) {
          _includeCoverBlankPage = refreshed.includeCoverBlankPage!;
        } else if (refreshed.coverPageTexts.containsKey(
          'includeCoverBlankPage',
        )) {
          _includeCoverBlankPage = _readCoverBlankPageFlag(
            refreshed.coverPageTexts['includeCoverBlankPage'],
          );
        }
        _includeAnswerSheet = refreshed.includeAnswerSheet;
        _includeExplanation = refreshed.includeExplanation;
        _includeQuestionScore = refreshed.includeQuestionScore;
        _previewFailureMessage = null;
        final refreshedTopText = refreshed.titlePageTopText.trim();
        final nextTopText = refreshedTopText.isNotEmpty
            ? refreshedTopText
            : _defaultTitlePageTopText;
        if (_titlePageTopTextController.text != nextTopText) {
          _titlePageTopTextController.text = nextTopText;
        }
        final refreshedGoalText = refreshed.titlePageGoalText.trim();
        final nextGoalText = refreshedGoalText.isNotEmpty
            ? refreshedGoalText
            : _defaultTitlePageGoalText;
        if (_titlePageGoalTextController.text != nextGoalText) {
          _titlePageGoalTextController.text = nextGoalText;
        }
        final refreshedTimeLimitText = refreshed.timeLimitText.trim();
        if (_timeLimitController.text != refreshedTimeLimitText) {
          _timeLimitController.text = refreshedTimeLimitText;
        }
        _questionScoreByQuestionId = _normalizeQuestionScoreMap(
          refreshed.questionScoreByQuestionId,
        );
        _syncCoverPageTextControllers(refreshed.coverPageTexts);
        if (_isTwoColumnLayout) {
          // 서버가 배치를 돌려주지 않으면(고정 배치라 자동 배치를 안 돌린 경우 등)
          // 현재 배치를 그대로 유지한다. 빈 값으로 덮으면 첫 자동 배치 결과가
          // 기본 균등 배치로 되돌아가 버린다.
          final refreshedOverrides = _parsePageOverrides(
            refreshed.pageColumnQuestionCounts,
          );
          if (refreshedOverrides.isNotEmpty) {
            _pageOverrides = refreshedOverrides;
          }
          _computedPageColumnCounts = _recomputePageColumnCounts();
          _columnLabelAnchorMap = _parseColumnLabelAnchors(
            refreshed.columnLabelAnchors,
          );
          _labelPanelPageSet = <int>{
            ..._labelPanelPageSet,
            ..._labelPagesFromAnchorMap(_columnLabelAnchorMap),
          };
          final refreshedTitles = refreshed.titlePageIndices.isNotEmpty
              ? refreshed.titlePageIndices
              : _titlePageIndexSet.toList(growable: false);
          _titlePageIndexSet = _normalizeTitlePageIndices(refreshedTitles);
          if (refreshed.titlePageHeaders.isNotEmpty) {
            _titlePageHeaderMap = _parseTitlePageHeaders(
              refreshed.titlePageHeaders,
            );
          }
          for (final entry in _labelControllers.entries) {
            final updated =
                '${_columnLabelAnchorMap[entry.key]?['label'] ?? ''}'.trim();
            if (entry.value.text != updated) {
              entry.value.text = updated;
            }
          }
          _syncPageScopedUiState();
        }
      });
    } finally {
      if (mounted) {
        setState(() {
          _isRefreshing = false;
        });
      }
    }
  }

  Future<void> _generatePdf() async {
    final callback = widget.onGeneratePdfRequested;
    if (callback == null || _isGeneratingPdf || _isRefreshing) return;
    setState(() {
      _isGeneratingPdf = true;
    });
    try {
      await callback(_buildRequestPayload());
    } finally {
      if (mounted) {
        setState(() {
          _isGeneratingPdf = false;
        });
      }
    }
  }

  String _defaultPresetDisplayName() {
    final last = _lastPresetDisplayName.trim();
    if (last.isNotEmpty) return last;
    final title = _titlePageTopTextController.text
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (title.isNotEmpty) {
      return '$title 세팅';
    }
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '문제은행 프리셋 ${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}';
  }

  Future<String?> _askPresetDisplayName() async {
    final controller = TextEditingController(text: _defaultPresetDisplayName());
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: kDlgBg,
          title: const Text('프리셋 이름', style: TextStyle(color: _textPrimary)),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: const TextStyle(
              color: _textPrimary,
              fontWeight: FontWeight.w700,
            ),
            decoration: const InputDecoration(hintText: '예: 3월 모의고사 출력세팅'),
            onSubmitted: (_) => Navigator.of(ctx).pop(controller.text.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
              child: const Text('저장'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    final normalized = (value ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) return null;
    return normalized;
  }

  String _defaultAssignmentDisplayName() {
    final title = _titlePageTopTextController.text
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final suffix =
        '${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}';
    return title.isEmpty ? '미리 만든 과제 $suffix' : '$title 과제';
  }

  Future<_AssignmentPromptResult?> _askAssignmentDisplayName() async {
    final controller = TextEditingController(
      text: _defaultAssignmentDisplayName(),
    );
    final flowNames = widget.assignmentFlowNames
        .map((e) => e.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    final value = await showDialog<_AssignmentPromptResult>(
      context: context,
      builder: (ctx) {
        var selectedFlowName = '';
        return StatefulBuilder(
          builder: (ctx, setPromptState) {
            void submit() {
              Navigator.of(ctx).pop(
                _AssignmentPromptResult(
                  displayName: controller.text.trim(),
                  flowName: selectedFlowName.trim(),
                ),
              );
            }

            return AlertDialog(
              backgroundColor: kDlgBg,
              title: const Text('과제 이름', style: TextStyle(color: _textPrimary)),
              content: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: controller,
                      autofocus: true,
                      style: const TextStyle(
                        color: _textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                      decoration: const InputDecoration(
                        hintText: '예: 경북고 공통수학1 21번 과제',
                      ),
                      onSubmitted: (_) => submit(),
                    ),
                    if (flowNames.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      const Text(
                        '드롭 시 사용할 플로우',
                        style: TextStyle(
                          color: _textMuted,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ChoiceChip(
                            label: const Text('지정 안 함'),
                            selected: selectedFlowName.isEmpty,
                            onSelected: (_) {
                              setPromptState(() {
                                selectedFlowName = '';
                              });
                            },
                          ),
                          for (final flowName in flowNames)
                            ChoiceChip(
                              label: Text(flowName),
                              selected: selectedFlowName == flowName,
                              onSelected: (_) {
                                setPromptState(() {
                                  selectedFlowName = flowName;
                                });
                              },
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('취소'),
                ),
                FilledButton(onPressed: submit, child: const Text('과제 생성')),
              ],
            );
          },
        );
      },
    );
    controller.dispose();
    final normalized = (value?.displayName ?? '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (normalized.isEmpty) return null;
    return _AssignmentPromptResult(
      displayName: normalized,
      flowName: (value?.flowName ?? '').replaceAll(RegExp(r'\s+'), ' ').trim(),
    );
  }

  Future<void> _createAssignmentPreset() async {
    final callback = widget.onCreateAssignmentRequested;
    if (callback == null || _isCreatingAssignment || _isRefreshing) return;
    final assignmentPrompt = await _askAssignmentDisplayName();
    if (assignmentPrompt == null) return;
    setState(() {
      _isCreatingAssignment = true;
    });
    try {
      final payload = _buildRequestPayload().copyWith(
        presetDisplayName: assignmentPrompt.displayName,
        presetIdToUpdate: '',
        assignmentFlowName: assignmentPrompt.flowName,
      );
      final created = await callback(payload);
      if (created && mounted) {
        Navigator.of(context).pop();
      }
    } finally {
      if (mounted) {
        setState(() {
          _isCreatingAssignment = false;
        });
      }
    }
  }

  /// 현재 편집 중인 프리셋(프리셋 카드에서 진입한 경우)에 덮어쓰기 저장.
  ///   - 이름 프롬프트 없이 기존 display_name 을 그대로 재사용한다.
  ///   - `_editingPresetId` 가 비어 있으면 호출되지 않도록 UI 에서 버튼을 비활성화한다.
  Future<void> _saveUpdateCurrentPreset() async {
    final callback = widget.onSaveSettingsRequested;
    if (callback == null || _isSavingSettings || _isRefreshing) return;
    final presetId = _editingPresetId.trim();
    if (presetId.isEmpty) {
      // 방어적 분기 — 이 경로는 UI 에서 진입할 수 없어야 한다.
      await _saveAsNewPreset();
      return;
    }
    final presetDisplayName = _editingPresetName.trim().isNotEmpty
        ? _editingPresetName.trim()
        : _defaultPresetDisplayName();
    setState(() {
      _isSavingSettings = true;
      _lastPresetDisplayName = presetDisplayName;
    });
    try {
      final payload = _buildRequestPayload().copyWith(
        presetDisplayName: presetDisplayName,
        presetIdToUpdate: presetId,
      );
      final saved = await callback(payload);
      if (!saved) return;
      if (mounted) {
        setState(() {
          _editingPresetName = presetDisplayName;
          _markCurrentStateSaved();
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSavingSettings = false;
        });
      }
    }
  }

  /// 새 프리셋으로 저장.
  ///   - 프리셋 이름을 프롬프트로 받고 `presetIdToUpdate` 는 빈 값으로 둔다.
  ///   - 저장 성공 후에는 같은 다이얼로그에서 방금 만든 프리셋을 "편집 중"으로 바꿔,
  ///     이후 "저장" 버튼이 덮어쓰기로 동작하도록 한다.
  Future<void> _saveAsNewPreset() async {
    final callback = widget.onSaveSettingsRequested;
    if (callback == null || _isSavingSettings || _isRefreshing) return;
    final presetDisplayName = await _askPresetDisplayName();
    if (presetDisplayName == null) return;
    setState(() {
      _isSavingSettings = true;
      _lastPresetDisplayName = presetDisplayName;
    });
    try {
      final payload = _buildRequestPayload().copyWith(
        presetDisplayName: presetDisplayName,
        presetIdToUpdate: '',
      );
      final saved = await callback(payload);
      if (saved && mounted) {
        Navigator.of(context).pop();
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSavingSettings = false;
        });
      }
    }
  }

  /// 오른쪽 옵션 패널 하단의 저장 버튼 영역.
  ///   - 프리셋 카드에서 진입한 경우(`_editingPresetId` 가 non-empty): '저장' + '새 세팅으로 저장' 두 버튼.
  ///   - 일반 미리보기에서 진입한 경우: '세팅 저장' 단일 버튼(= save-as-new).
  Widget _buildCreateAssignmentButton() {
    final hasCallback = widget.onCreateAssignmentRequested != null;
    final busy =
        _isSavingSettings ||
        _isGeneratingPdf ||
        _isCreatingAssignment ||
        _isRefreshing;
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: hasCallback && !busy ? _createAssignmentPreset : null,
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF24422D),
          foregroundColor: const Color(0xFFD8F7DA),
          disabledBackgroundColor: const Color(0xFF18281E),
          disabledForegroundColor: const Color(0xFF86A98B),
          minimumSize: const Size.fromHeight(42),
          shape: const StadiumBorder(),
        ),
        icon: _isCreatingAssignment
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.assignment_add, size: 18),
        label: const Text(
          '과제 생성',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
        ),
      ),
    );
  }

  Widget _buildSaveSettingsButtons() {
    final hasCallback = widget.onSaveSettingsRequested != null;
    final busy =
        _isSavingSettings ||
        _isGeneratingPdf ||
        _isCreatingAssignment ||
        _isRefreshing;
    final canSave = hasCallback && !busy;
    final editingLabel = _editingPresetName.trim().isEmpty
        ? '현재 프리셋'
        : _editingPresetName.trim();
    final isEditingPreset = _editingPresetId.trim().isNotEmpty;

    Widget primaryUpdateButton() {
      return FilledButton.icon(
        onPressed: canSave ? _saveUpdateCurrentPreset : null,
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF1F3842),
          foregroundColor: const Color(0xFFD9F0FF),
          disabledBackgroundColor: const Color(0xFF1A2A31),
          disabledForegroundColor: const Color(0xFF86A4B3),
          minimumSize: const Size.fromHeight(42),
          shape: const StadiumBorder(),
        ),
        icon: _isSavingSettings
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.save_outlined, size: 18),
        label: const Text(
          '저장',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
        ),
      );
    }

    Widget secondarySaveAsNewButton({bool primary = false}) {
      return OutlinedButton.icon(
        onPressed: canSave ? _saveAsNewPreset : null,
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFFD9F0FF),
          disabledForegroundColor: const Color(0xFF86A4B3),
          side: const BorderSide(color: Color(0xFF2F4B55), width: 1.2),
          minimumSize: const Size.fromHeight(42),
          shape: const StadiumBorder(),
          backgroundColor: primary
              ? const Color(0xFF1F3842)
              : const Color(0xFF121C21),
        ),
        icon: _isSavingSettings
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.note_add_outlined, size: 18),
        label: const Text(
          '새 세팅으로 저장',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
        ),
      );
    }

    if (!isEditingPreset) {
      // 프리셋 카드 진입이 아닌 경우: 단일 "세팅 저장" 버튼.
      //   내부 동작은 save-as-new 와 동일하다(프리셋 이름 프롬프트).
      return SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: canSave ? _saveAsNewPreset : null,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF1F3842),
            foregroundColor: const Color(0xFFD9F0FF),
            disabledBackgroundColor: const Color(0xFF1A2A31),
            disabledForegroundColor: const Color(0xFF86A4B3),
            minimumSize: const Size.fromHeight(42),
            shape: const StadiumBorder(),
          ),
          icon: _isSavingSettings
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_outlined, size: 18),
          label: const Text(
            '세팅 저장',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
          ),
        ),
      );
    }

    // 프리셋 카드 진입: 덮어쓰기("저장") + 신규 저장 두 버튼.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            '편집 중: $editingLabel',
            style: const TextStyle(
              color: Color(0xFFB6C9CF),
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        primaryUpdateButton(),
        const SizedBox(height: 8),
        secondarySaveAsNewButton(),
      ],
    );
  }

  Widget _buildSectionCard({required String title, required Widget child}) {
    final style = _settingsStyle(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: _settingsGroupedFill(context),
        borderRadius: BorderRadius.circular(
          FabTabBarTokens.previewAcademyGroupedCardRadius,
        ),
        border: _settingsGroupedBorder(context),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: style.title,
              fontSize: 14,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  Widget _buildTitleSwitchTile({
    required String label,
    required String description,
    required bool value,
    required ValueChanged<bool> onChanged,
    Widget? trailingAction,
  }) {
    final style = _settingsStyle(context);
    final brightness = Theme.of(context).brightness;
    final tileColor = brightness == Brightness.dark
        ? const Color(0xFF1C1C1E)
        : const Color(0xFFF2F2F7);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 11, 12, 11),
      decoration: BoxDecoration(
        color: tileColor,
        borderRadius: BorderRadius.circular(18),
        border: _settingsGroupedBorder(context),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: style.title,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: TextStyle(
                    color: style.hint,
                    fontSize: 11.4,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          if (trailingAction != null) ...[
            const SizedBox(width: 6),
            trailingAction,
          ],
          const SizedBox(width: 8),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: const Color(0xFFFFFFFF),
            activeTrackColor: FabTabBarTokens.previewConfirmActionColor,
            inactiveThumbColor: brightness == Brightness.dark
                ? const Color(0xFF8E8E93)
                : null,
            inactiveTrackColor: brightness == Brightness.dark
                ? const Color(0xFF3A3A3C)
                : null,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ],
      ),
    );
  }

  Widget _buildCoverTextField({
    required String label,
    required TextEditingController controller,
    String? hintText,
  }) {
    final style = _settingsStyle(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: controller,
        style: TextStyle(
          color: style.inputText,
          fontSize: 12.6,
          fontWeight: FontWeight.w700,
        ),
        decoration: InputDecoration(
          labelText: label,
          hintText: hintText,
          isDense: true,
          filled: true,
          fillColor: _settingsGroupedFill(context),
          labelStyle: TextStyle(
            color: style.label,
            fontSize: 12.0,
            fontWeight: FontWeight.w700,
          ),
          hintStyle: TextStyle(
            color: style.hint,
            fontSize: 11.8,
            fontWeight: FontWeight.w600,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: style.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(
              color: FabTabBarTokens.previewConfirmActionColor,
              width: 1.1,
            ),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 10,
          ),
        ),
      ),
    );
  }

  Widget _buildCoverInlineTextField({
    required String label,
    required TextEditingController controller,
    String? hintText,
  }) {
    final style = _settingsStyle(context);
    return TextField(
      controller: controller,
      style: TextStyle(
        color: style.inputText,
        fontSize: 12.3,
        fontWeight: FontWeight.w700,
      ),
      decoration: InputDecoration(
        labelText: label,
        hintText: hintText,
        isDense: true,
        filled: true,
        fillColor: _settingsGroupedFill(context),
        labelStyle: TextStyle(
          color: style.label,
          fontSize: 11.7,
          fontWeight: FontWeight.w700,
        ),
        hintStyle: TextStyle(
          color: style.hint,
          fontSize: 11.3,
          fontWeight: FontWeight.w600,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: style.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(
            color: FabTabBarTokens.previewConfirmActionColor,
            width: 1.1,
          ),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      ),
    );
  }

  Widget _buildCoverSubjectGroupEditor({
    required String title,
    required int groupIndex,
    required TextEditingController labelController,
    required TextEditingController pageRangeController,
    required List<TextEditingController> itemNameControllers,
    required List<TextEditingController> itemPageControllers,
  }) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      decoration: BoxDecoration(
        color: const Color(0xFF101920),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF263740)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: _textPrimary,
                    fontSize: 12.2,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: () => _addCoverSubjectItem(groupIndex: groupIndex),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: const Color(0xFFC7F2D8),
                ),
                icon: const Icon(Icons.add, size: 15),
                label: const Text('하위과목 추가'),
              ),
              IconButton(
                onPressed: () => _removeCoverSubjectGroup(groupIndex),
                tooltip: '대분류 삭제',
                icon: const Icon(
                  Icons.delete_outline_rounded,
                  size: 18,
                  color: Color(0xFFB8C8CE),
                ),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: _buildCoverInlineTextField(
                  label: '대분류명',
                  controller: labelController,
                  hintText: '대분류명',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: _buildCoverInlineTextField(
                  label: '대분류 페이지(선택)',
                  controller: pageRangeController,
                  hintText: '1~12쪽',
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          if (itemNameControllers.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 2, bottom: 2),
              child: Text(
                '하위과목이 없습니다. `하위과목 추가`로 새 항목을 추가하세요.',
                style: TextStyle(
                  color: _textMuted,
                  fontSize: 11.2,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          for (
            var i = 0;
            i <
                math.min(
                  itemNameControllers.length,
                  itemPageControllers.length,
                );
            i += 1
          )
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: _buildCoverInlineTextField(
                      label: '하위과목 ${i + 1}',
                      controller: itemNameControllers[i],
                      hintText: '과목명',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: _buildCoverInlineTextField(
                      label: '페이지',
                      controller: itemPageControllers[i],
                      hintText: '9~12쪽',
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: () => _removeCoverSubjectItem(
                      groupIndex: groupIndex,
                      itemIndex: i,
                    ),
                    tooltip: '하위과목 삭제',
                    icon: const Icon(
                      Icons.remove_circle_outline_rounded,
                      size: 18,
                      color: Color(0xFFB8C8CE),
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildGyeongsinInfoEditor() {
    final isNeungin = widget.isNeunginTemplate;
    final isDaeryun = widget.isDaeryunTemplate;
    final isDongdo = widget.isDongdoTemplate;
    final isSoseon = widget.isSoseonTemplate;
    final isOseong = widget.isOseongTemplate;
    final isJeonghwa = widget.isJeonghwaTemplate;
    final isHwanggeum = widget.isHwanggeumTemplate;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 9, 10, 4),
      decoration: BoxDecoration(
        color: const Color(0xFF0C1419),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF23333B)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isDaeryun
                ? '대륜중 시험 정보 (자동 반영 / 수동 수정)'
                : (isDongdo
                      ? '동도중 시험 정보 (자동 반영 / 수동 수정)'
                      : (isSoseon
                            ? '소선여중 시험 정보 (자동 반영 / 수동 수정)'
                            : (isOseong
                                  ? '오성중 시험 정보 (자동 반영 / 수동 수정)'
                                  : (isJeonghwa
                                        ? '정화중 시험 정보 (자동 반영 / 수동 수정)'
                                        : (isHwanggeum
                                              ? '황금중 시험 정보 (자동 반영 / 수동 수정)'
                                              : (isNeungin
                                                    ? '능인중 시험 정보 (자동 반영 / 수동 수정)'
                                                    : '경신중 시험 정보 (자동 반영 / 수동 수정)')))))),
            style: const TextStyle(
              color: _textPrimary,
              fontSize: 12.4,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            isDaeryun
                ? '날짜를 입력하면 요일이 자동 계산됩니다. 선택형·서술형(주관식 포함) 문항 수와 총 장·면 수는 비워두면 자동으로 계산됩니다.'
                : (isDongdo
                      ? '총문항·선택형·서술형(주관식 포함) 문항 수와 총 장·면 수, 점수는 비워두면 자동으로 계산됩니다.'
                      : (isSoseon
                            ? '표지 및 1페이지 상단의 문항 수(선택형·서술형·계)와 전체 면수는 비워두면 자동으로 계산됩니다.'
                            : (isOseong
                                  ? '1페이지 상단의 선택형 점수별 문항 수·서술형 배점 및 전체 면수는 비워두면 자동으로 계산됩니다.'
                                  : (isJeonghwa
                                        ? '표지 구성표의 문항 수(선택형·단답형·서술형), 총점, 전체 면수는 비워두면 자동으로 계산됩니다.'
                                        : (isHwanggeum
                                              ? '표지 구성표의 문항 수(선택형·서답형), 배점, 총 장·면 수는 비워두면 자동으로 계산됩니다.'
                                              : (isNeungin
                                                    ? '문항 수(선택형·단답형·서논술형)와 전체 면수는 비워두면 실제 문항/페이지 수로 자동 계산됩니다.'
                                                    : '날짜를 입력하면 요일이 자동 계산되고 2교시는 고정됩니다. 문항 수와 전체 면수는 비워두면 실제 문항/페이지 수로 자동 계산됩니다.')))))),
            style: const TextStyle(
              color: _textMuted,
              fontSize: 11.2,
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 8),
          if (isDaeryun) ...[
            Row(
              children: [
                Expanded(
                  child: _buildCoverTextField(
                    label: '시험일시 (예: 2026.9.22)',
                    controller: _gyeongsinExamDateController,
                    hintText: _koreaTodayExamDate(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildCoverTextField(
                    label: '교시',
                    controller: _gyeongsinPeriodLabelController,
                    hintText: '제 2 교시',
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: _buildCoverTextField(
                    label: '답안지 형',
                    controller: _gyeongsinSheetTypeController,
                    hintText: '답안지 D형',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildCoverTextField(
                    label: '과목코드',
                    controller: _gyeongsinSubjectCodeController,
                    hintText: '04',
                  ),
                ),
              ],
            ),
          ] else if (isDongdo) ...[
            Row(
              children: [
                Expanded(
                  child: _buildCoverTextField(
                    label: '과목코드',
                    controller: _gyeongsinSubjectCodeController,
                    hintText: '05',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildCoverTextField(
                    label: '선택형 점수 (비우면 80점)',
                    controller: _gyeongsinObjectiveScoreController,
                    hintText: '80점',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildCoverTextField(
                    label: '서술형 점수 (비우면 20점)',
                    controller: _gyeongsinEssayScoreController,
                    hintText: '20점',
                  ),
                ),
              ],
            ),
          ] else if (isOseong) ...[
            Row(
              children: [
                Expanded(
                  child: _buildCoverTextField(
                    label: '교시',
                    controller: _gyeongsinPeriodLabelController,
                    hintText: '제 1 교시',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildCoverTextField(
                    label: '과목 코드',
                    controller: _gyeongsinSubjectCodeController,
                    hintText: '04',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildCoverTextField(
                    label: '서술형 배점 (자동)',
                    controller: _gyeongsinEssayScoreController,
                    hintText: '35점',
                  ),
                ),
              ],
            ),
          ] else if (isNeungin || isSoseon || isJeonghwa || isHwanggeum)
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: _buildCoverTextField(
                    label: '실시일자 (예: 2026.10.27)',
                    controller: _gyeongsinExamDateController,
                    hintText: _koreaTodayExamDate(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildCoverTextField(
                    label: '교시',
                    controller: _gyeongsinPeriodLabelController,
                    hintText: isSoseon
                        ? '3교시'
                        : ((isJeonghwa || isHwanggeum) ? '1교시' : '제 1교시'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildCoverTextField(
                    label: '과목 코드',
                    controller: _gyeongsinSubjectCodeController,
                    hintText: (isSoseon || isHwanggeum) ? '04' : '05',
                  ),
                ),
              ],
            )
          else
            _buildCoverTextField(
              label: '실시일자 (예: 2026.10.26 — 요일 자동·2교시 고정)',
              controller: _gyeongsinExamDateController,
              hintText: _koreaTodayExamDate(),
            ),
          _buildCoverTextField(
            label: (isDaeryun || isDongdo) ? '1페이지 상단 시험명' : '표지 시험명 (1페이지 상단)',
            controller: _gyeongsinCoverExamTitleController,
            hintText: isDaeryun
                ? '2026학년도 2학기 중간시험 2학년 문제지'
                : (isDongdo
                      ? '2026학년도 수학과 제3학년 2학기 기말고사'
                      : (isSoseon
                            ? '2026학년도 2학기 3학년 기말시험 문제지'
                            : (isOseong
                                  ? '2026학년도 2학기 기말시험'
                                  : (isJeonghwa
                                        ? '2026학년도 2학년 2학기 중간시험'
                                        : (isHwanggeum
                                              ? '2026학년도 1학기 기말시험 3학년'
                                              : (isNeungin
                                                    ? '2026학년도 2학기 3학년 중간시험 문제지'
                                                    : '2026학년도 3학년 2학기 기말시험')))))),
          ),
          if (!isNeungin && !isDaeryun && !isDongdo && !isJeonghwa && !isHwanggeum)
            _buildCoverTextField(
              label: '문제지 상단 시험명 (문제 첫 페이지)',
              controller: _gyeongsinHeaderExamTitleController,
              hintText: isSoseon
                  ? '3학년 2학기 기말시험'
                  : (isOseong ? '2026학년도 오성중학교 2학기 기말시험 문제지' : '제 3 학년 2 학기 기말시험'),
            ),
          _buildCoverTextField(
            label: '과목명 (기본 수학)',
            controller: _gyeongsinSubjectNameController,
            hintText: '수학',
          ),
          if (isNeungin || isJeonghwa)
            Row(
              children: [
                Expanded(
                  child: _buildCoverTextField(
                    label: '선택형 문항 수 (자동)',
                    controller: _gyeongsinObjectiveCountController,
                    hintText: '자동',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildCoverTextField(
                    label: '단답형 문항 수 (자동)',
                    controller: _gyeongsinSubjectiveCountController,
                    hintText: '자동',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildCoverTextField(
                    label: isJeonghwa ? '서술형 문항 수 (자동)' : '서·논술형 문항 수 (자동)',
                    controller: _gyeongsinEssayCountController,
                    hintText: '자동',
                  ),
                ),
              ],
            )
          else
            Row(
              children: [
                Expanded(
                  child: _buildCoverTextField(
                    label: '선택형 문항 수 (비우면 자동)',
                    controller: _gyeongsinObjectiveCountController,
                    hintText: '자동',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildCoverTextField(
                    label: '서술형 문항 수 (비우면 자동)',
                    controller: _gyeongsinEssayCountController,
                    hintText: '자동',
                  ),
                ),
              ],
            ),
          if (isJeonghwa || isHwanggeum)
            Row(
              children: [
                Expanded(
                  child: _buildCoverTextField(
                    label: '선택형 총점 (비우면 자동)',
                    controller: _gyeongsinObjectiveScoreController,
                    hintText: isHwanggeum ? '65점' : '40',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildCoverTextField(
                    label: '서답형 총점 (비우면 자동)',
                    controller: _gyeongsinEssayScoreController,
                    hintText: isHwanggeum ? '35점' : '60',
                  ),
                ),
              ],
            ),
          Row(
            children: [
              Expanded(
                child: _buildCoverTextField(
                  label: '전체 문제지 면 수 (비우면 자동)',
                  controller: _gyeongsinTotalPageCountController,
                  hintText: '자동',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildCoverTextField(
                  label: '시작 페이지 번호 (기본 1)',
                  controller: _gyeongsinPageStartController,
                  hintText: '1',
                ),
              ),
            ],
          ),
          if (!isNeungin)
            _buildCoverTextField(
              label: isDaeryun
                  ? '하단 우측 문구 (비우면 자동: 대륜중학교 · 학년 · 과목)'
                  : (isDongdo
                        ? '하단 좌측 문구 (비우면 자동: (동도중) · 학년 · 과목)'
                        : (isSoseon
                              ? '하단 과목 문구 (비우면 자동: 학년 · 과목 · 교과)'
                              : (isOseong
                                    ? '하단 과목 문구 (비우면 자동: 중학년-과목)'
                                    : (isJeonghwa
                                          ? '하단 과목 문구 (비우면 자동: 정화중학교 · 학년 · 과목)'
                                          : (isHwanggeum
                                                ? '하단 우측 문구 (비우면 자동: 학년 · 과목과 · 황금중학교)'
                                                : '하단 소속/학년 문구 (비우면 자동: 출처 학교 · 과목 · 학년)'))))),
              controller: _gyeongsinFooterLabelController,
              hintText: isDaeryun
                  ? '대륜중학교 2학년 수학'
                  : (isDongdo
                        ? '(동도중) 3학년 수학'
                        : (isSoseon
                              ? '3학년 수학 교과'
                              : (isOseong
                                    ? '중3-수학'
                                    : (isJeonghwa
                                          ? '정화중학교 2학년 수학'
                                          : (isHwanggeum
                                                ? '3학년 수학과 황금중학교'
                                                : '경신중 수학 3학년'))))),
            ),
        ],
      ),
    );
  }

  Widget _buildCoverPageTextEditor() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
      decoration: BoxDecoration(
        color: const Color(0xFF0C1419),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF23333B)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '표지 문구',
            style: TextStyle(
              color: _textPrimary,
              fontSize: 12.4,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            '표지 ON일 때만 반영되며, 표지 과목명은 본문 1페이지 제목과 분리됩니다.',
            style: TextStyle(
              color: _textMuted,
              fontSize: 11.2,
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 8),
          _buildCoverTextField(
            label: '상단 제목',
            controller: _coverTopTitleController,
            hintText: '2026학년도 대학수학능력시험 문제지',
          ),
          _buildCoverTextField(
            label: '표지 과목명 (cover-only)',
            controller: _coverSubjectTitleController,
            hintText: '수학 영역',
          ),
          _buildCoverTextField(
            label: '필적확인 문구',
            controller: _coverPhraseController,
            hintText: '이 많은 별빛이 내린 언덕 위에',
          ),
          const SizedBox(height: 2),
          const Text(
            '과목 리스트 (대분류 → 하위과목)',
            style: TextStyle(
              color: _textMuted,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _addCoverSubjectGroup(),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                foregroundColor: const Color(0xFFC7F2D8),
              ),
              icon: const Icon(Icons.add_box_outlined, size: 16),
              label: const Text('대분류 추가'),
            ),
          ),
          if (_coverGroupLabelControllers.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 4, bottom: 8),
              child: Text(
                '대분류가 없습니다. `대분류 추가`로 새 과목 그룹을 만드세요.',
                style: TextStyle(
                  color: _textMuted,
                  fontSize: 11.3,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          for (
            var groupIndex = 0;
            groupIndex <
                math.min(
                  _coverGroupLabelControllers.length,
                  math.min(
                    _coverGroupPageRangeControllers.length,
                    math.min(
                      _coverGroupItemNameControllers.length,
                      _coverGroupItemPageControllers.length,
                    ),
                  ),
                );
            groupIndex += 1
          )
            _buildCoverSubjectGroupEditor(
              title: '대분류 ${groupIndex + 1}',
              groupIndex: groupIndex,
              labelController: _coverGroupLabelControllers[groupIndex],
              pageRangeController: _coverGroupPageRangeControllers[groupIndex],
              itemNameControllers: _coverGroupItemNameControllers[groupIndex],
              itemPageControllers: _coverGroupItemPageControllers[groupIndex],
            ),
          _buildCoverTextField(
            label: '기관명',
            controller: _coverOrganizationController,
            hintText: '한국교육과정평가원',
          ),
        ],
      ),
    );
  }

  Widget _buildColumnStepper({
    required String label,
    required int value,
    required VoidCallback onIncrease,
    required VoidCallback onDecrease,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF0C1418),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF213037)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                color: _textMuted,
                fontSize: 11.4,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                IconButton(
                  onPressed: onDecrease,
                  icon: const Icon(Icons.keyboard_arrow_down_rounded),
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  color: _textMuted,
                  tooltip: '감소',
                ),
                Expanded(
                  child: Text(
                    '$value',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: _textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: onIncrease,
                  icon: const Icon(Icons.keyboard_arrow_up_rounded),
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  color: _textMuted,
                  tooltip: '증가',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPageCardPill({
    required String label,
    required bool selected,
    required VoidCallback? onPressed,
  }) {
    return SizedBox(
      height: 26,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          minimumSize: const Size(0, 26),
          shape: const StadiumBorder(),
          foregroundColor: selected ? const Color(0xFFC7F2D8) : _textMuted,
          backgroundColor: selected
              ? const Color(0xFF173C36)
              : const Color(0xFF131E24),
          side: BorderSide(
            color: selected ? const Color(0xFF2A6D5F) : const Color(0xFF2A3841),
            width: 1,
          ),
          visualDensity: VisualDensity.compact,
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 11.2, fontWeight: FontWeight.w800),
        ),
      ),
    );
  }

  List<MapEntry<String, Map<String, dynamic>>> _anchorRowsForColumn({
    required int pageIndex,
    required int columnIndex,
  }) {
    final pageNo = pageIndex + 1;
    final out = _columnLabelAnchorMap.entries
        .where((entry) {
          final row = entry.value;
          final page = int.tryParse('${row['page'] ?? 0}') ?? 0;
          final col = int.tryParse('${row['columnIndex'] ?? -1}') ?? -1;
          final rowIndex = int.tryParse('${row['rowIndex'] ?? 0}') ?? -1;
          return page == pageNo &&
              col == columnIndex &&
              rowIndex >= 0 &&
              rowIndex < 99;
        })
        .toList(growable: true);
    out.sort((a, b) {
      final rowA = int.tryParse('${a.value['rowIndex'] ?? 0}') ?? 0;
      final rowB = int.tryParse('${b.value['rowIndex'] ?? 0}') ?? 0;
      return rowA.compareTo(rowB);
    });
    return out;
  }

  int? _nextAvailableAnchorRowIndex({
    required int pageIndex,
    required int columnIndex,
  }) {
    if (pageIndex < 0 || pageIndex >= _computedPageColumnCounts.length) {
      return null;
    }
    final pageCounts = _computedPageColumnCounts[pageIndex];
    if (columnIndex < 0 || columnIndex >= pageCounts.length) return null;
    final rowLimit = pageCounts[columnIndex];
    if (rowLimit <= 0) return null;
    final used =
        _anchorRowsForColumn(pageIndex: pageIndex, columnIndex: columnIndex)
            .map(
              (entry) => int.tryParse('${entry.value['rowIndex'] ?? 0}') ?? -1,
            )
            .where((row) => row >= 0)
            .toSet();
    for (var row = 0; row < rowLimit; row += 1) {
      if (!used.contains(row)) return row;
    }
    return null;
  }

  Widget _buildAnchorEditor({
    required int pageIndex,
    required int columnIndex,
    required String title,
  }) {
    final anchors = _anchorRowsForColumn(
      pageIndex: pageIndex,
      columnIndex: columnIndex,
    );
    final addableRowIndex = _nextAvailableAnchorRowIndex(
      pageIndex: pageIndex,
      columnIndex: columnIndex,
    );
    if (anchors.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(8, 7, 8, 7),
        decoration: BoxDecoration(
          color: const Color(0xFF0C1418),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF213037)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '$title 라벨 없음',
                style: const TextStyle(
                  color: _textMuted,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            IconButton(
              onPressed: addableRowIndex == null
                  ? null
                  : () => _addDefaultAnchor(
                      pageIndex: pageIndex,
                      columnIndex: columnIndex,
                      rowIndex: addableRowIndex,
                    ),
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              tooltip: '라벨 추가',
              color: _textPrimary,
              icon: const Icon(Icons.add_circle_outline_rounded),
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...anchors.map((entry) {
          final row = entry.value;
          final rowIndex = int.tryParse('${row['rowIndex'] ?? 0}') ?? 0;
          final controller = _controllerForAnchor(
            pageIndex: pageIndex,
            columnIndex: columnIndex,
            rowIndex: rowIndex,
          );
          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: TextField(
              controller: controller,
              style: const TextStyle(
                color: _textPrimary,
                fontSize: 12.4,
                fontWeight: FontWeight.w700,
              ),
              cursorColor: _textPrimary,
              onChanged: (value) {
                _setAnchorLabel(
                  pageIndex: pageIndex,
                  columnIndex: columnIndex,
                  rowIndex: rowIndex,
                  rawLabel: value,
                );
              },
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: const Color(0xFF0C1418),
                labelText: '$title 라벨 (행 ${rowIndex + 1})',
                labelStyle: const TextStyle(
                  color: _textMuted,
                  fontSize: 11.8,
                  fontWeight: FontWeight.w700,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 9,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFF213037)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: _accent, width: 1.1),
                ),
                suffixIcon: IconButton(
                  onPressed: () {
                    controller.clear();
                    _setAnchorLabel(
                      pageIndex: pageIndex,
                      columnIndex: columnIndex,
                      rowIndex: rowIndex,
                      rawLabel: '',
                    );
                    setState(() {});
                  },
                  icon: const Icon(Icons.close_rounded, size: 16),
                  tooltip: '라벨 제거',
                  color: _textMuted,
                ),
              ),
            ),
          );
        }),
        if (addableRowIndex != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => _addDefaultAnchor(
                pageIndex: pageIndex,
                columnIndex: columnIndex,
                rowIndex: addableRowIndex,
              ),
              icon: const Icon(Icons.add_rounded, size: 16),
              label: const Text('라벨 추가'),
              style: TextButton.styleFrom(
                foregroundColor: _textPrimary,
                visualDensity: VisualDensity.compact,
                textStyle: const TextStyle(
                  fontSize: 11.8,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPageNoticeEditor({required int pageIndex}) {
    final key = _anchorKey(pageIndex, 1, rowIndex: 99);
    final hasNotice = _columnLabelAnchorMap.containsKey(key);
    if (!hasNotice) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(8, 7, 8, 7),
        decoration: BoxDecoration(
          color: const Color(0xFF0C1418),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF213037)),
        ),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                '하단 안내박스 없음',
                style: TextStyle(
                  color: _textMuted,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            IconButton(
              onPressed: () {
                final isLastPage =
                    pageIndex == _computedPageColumnCounts.length - 1;
                final nextSub =
                    (_titlePageHeaderMap[pageIndex + 2]?['subtitle'] ?? '')
                        .trim();
                final defaultText = isLastPage
                    ? '확인 사항'
                    : '선택과목(${nextSub.isNotEmpty ? nextSub : '확률과 통계'})';
                final controller = _controllerForAnchor(
                  pageIndex: pageIndex,
                  columnIndex: 1,
                  rowIndex: 99,
                );
                controller.text = defaultText;
                _setAnchorLabel(
                  pageIndex: pageIndex,
                  columnIndex: 1,
                  rowIndex: 99,
                  rawLabel: defaultText,
                );
                setState(() {});
              },
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              tooltip: '안내박스 추가',
              color: _textPrimary,
              icon: const Icon(Icons.add_circle_outline_rounded),
            ),
          ],
        ),
      );
    }
    final controller = _controllerForAnchor(
      pageIndex: pageIndex,
      columnIndex: 1,
      rowIndex: 99,
    );
    return TextField(
      controller: controller,
      style: const TextStyle(
        color: _textPrimary,
        fontSize: 12.4,
        fontWeight: FontWeight.w700,
      ),
      cursorColor: _textPrimary,
      onChanged: (value) {
        _setAnchorLabel(
          pageIndex: pageIndex,
          columnIndex: 1,
          rowIndex: 99,
          rawLabel: value,
        );
      },
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: const Color(0xFF0C1418),
        labelText: '하단 안내박스 (확인 사항 또는 선택과목명)',
        labelStyle: const TextStyle(
          color: _textMuted,
          fontSize: 11.8,
          fontWeight: FontWeight.w700,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 9,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF213037)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _accent, width: 1.1),
        ),
        suffixIcon: IconButton(
          onPressed: () {
            controller.clear();
            _setAnchorLabel(
              pageIndex: pageIndex,
              columnIndex: 1,
              rowIndex: 99,
              rawLabel: '',
            );
            setState(() {});
          },
          icon: const Icon(Icons.close_rounded, size: 16),
          tooltip: '안내박스 제거',
          color: _textMuted,
        ),
      ),
    );
  }

  Widget _buildTitleHeaderEditor(int pageNo) {
    final titleController = _titleControllerForPage(pageNo);
    final subtitleController = _subtitleControllerForPage(pageNo);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0C1418),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF213037)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: titleController,
            style: const TextStyle(
              color: _textPrimary,
              fontSize: 12.6,
              fontWeight: FontWeight.w700,
            ),
            cursorColor: _textPrimary,
            onChanged: (value) => _setTitleHeader(pageNo: pageNo, title: value),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: _panelSectionBg,
              labelText: '제목 페이지 타이틀',
              labelStyle: const TextStyle(
                color: _textMuted,
                fontSize: 11.8,
                fontWeight: FontWeight.w700,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 9,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFF213037)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: _accent, width: 1.1),
              ),
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: subtitleController,
            style: const TextStyle(
              color: _textPrimary,
              fontSize: 12.2,
              fontWeight: FontWeight.w700,
            ),
            cursorColor: _textPrimary,
            onChanged: (value) =>
                _setTitleHeader(pageNo: pageNo, subtitle: value),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: _panelSectionBg,
              labelText: '부제 (괄호 없이 입력)',
              labelStyle: const TextStyle(
                color: _textMuted,
                fontSize: 11.6,
                fontWeight: FontWeight.w700,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 9,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFF213037)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: _accent, width: 1.1),
              ),
            ),
          ),
          const SizedBox(height: 5),
          const Text(
            '렌더 형식: 타이틀(부제) / 부제는 타이틀보다 10% 작게 렌더됩니다.',
            style: TextStyle(
              color: Color(0xFF8DA3A6),
              fontSize: 11.0,
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPageLayoutCards() {
    if (!_isTwoColumnLayout) {
      return const Text(
        '2단 레이아웃에서만 페이지별 좌/우 문항 수를 수정할 수 있습니다.',
        style: TextStyle(
          color: Color(0xFF9FB3B3),
          fontSize: 12.2,
          fontWeight: FontWeight.w600,
          height: 1.35,
        ),
      );
    }
    if (_computedPageColumnCounts.isEmpty) {
      return const Text(
        '선택된 문항이 없어 페이지 카드가 표시되지 않습니다.',
        style: TextStyle(
          color: Color(0xFF9FB3B3),
          fontSize: 12.2,
          fontWeight: FontWeight.w600,
          height: 1.35,
        ),
      );
    }
    return Column(
      children: [
        const Text(
          '자동 배치 결과를 기준으로 페이지별 좌/우 문항 수를 조정합니다. 라벨/제목 버튼으로 각 페이지의 라벨 편집 영역과 제목 페이지 양식을 토글할 수 있습니다.',
          style: TextStyle(
            color: Color(0xFF8DA3A6),
            fontSize: 11.4,
            fontWeight: FontWeight.w600,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 8),
        ..._computedPageColumnCounts.asMap().entries.map((entry) {
          final index = entry.key;
          final pageNo = index + 1;
          final counts = entry.value;
          final left = counts[0];
          final right = counts[1];
          final labelVisible = _isLabelPanelVisible(pageNo);
          final titleSelected = _isTitlePage(pageNo);
          return Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.fromLTRB(9, 8, 9, 9),
            decoration: BoxDecoration(
              color: const Color(0xFF0D161A),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: const Color(0xFF203038)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '$pageNo페이지',
                      style: const TextStyle(
                        color: _textPrimary,
                        fontSize: 12.4,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Spacer(),
                    _buildPageCardPill(
                      label: '라벨',
                      selected: labelVisible,
                      onPressed: () => _toggleLabelPanel(pageNo),
                    ),
                    const SizedBox(width: 6),
                    _buildPageCardPill(
                      label: '제목',
                      selected: titleSelected,
                      onPressed: pageNo == 1
                          ? null
                          : () => _toggleTitlePage(pageNo),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    _buildColumnStepper(
                      label: '왼쪽 단',
                      value: left,
                      onIncrease: () => _applyPageColumnDelta(
                        pageIndex: index,
                        isLeft: true,
                        delta: 1,
                      ),
                      onDecrease: () => _applyPageColumnDelta(
                        pageIndex: index,
                        isLeft: true,
                        delta: -1,
                      ),
                    ),
                    const SizedBox(width: 6),
                    _buildColumnStepper(
                      label: '오른쪽 단',
                      value: right,
                      onIncrease: () => _applyPageColumnDelta(
                        pageIndex: index,
                        isLeft: false,
                        delta: 1,
                      ),
                      onDecrease: () => _applyPageColumnDelta(
                        pageIndex: index,
                        isLeft: false,
                        delta: -1,
                      ),
                    ),
                  ],
                ),
                if (labelVisible) ...[
                  const SizedBox(height: 8),
                  _buildAnchorEditor(
                    pageIndex: index,
                    columnIndex: 0,
                    title: '왼쪽 단',
                  ),
                  const SizedBox(height: 6),
                  _buildAnchorEditor(
                    pageIndex: index,
                    columnIndex: 1,
                    title: '오른쪽 단',
                  ),
                  if (!widget.isAssignmentTemplate &&
                      !widget.isGyeongsinTemplate &&
                      !widget.isNeunginTemplate &&
                      !widget.isDaeryunTemplate &&
                      !widget.isDongdoTemplate &&
                      !widget.isSoseonTemplate &&
                      !widget.isOseongTemplate &&
                      !widget.isJeonghwaTemplate &&
                      !widget.isHwanggeumTemplate) ...[
                    const SizedBox(height: 6),
                    _buildPageNoticeEditor(pageIndex: index),
                  ],
                ],
                if (titleSelected) ...[
                  const SizedBox(height: 8),
                  _buildTitleHeaderEditor(pageNo),
                ],
              ],
            ),
          );
        }),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final panelStyle = FabTabBarTokens.previewAcademyPanelStyleFor(brightness);
    final panelCardBackground = panelStyle.groupedCardBackground;
    final panelCardBorder = FabTabBarTokens.groupedCardBorderFor(brightness);
    final panelButtonBackground = brightness == Brightness.dark
        ? const Color(0xFF2C2C2E)
        : const Color(0xFFEAF3FF);
    final expandedSettingsPanelWidth = _expandedSettingsPanelWidthFor(
      widget.expandedDialogSize.width,
    );
    final settingsPanelWidth = _settingsPanelExpanded
        ? expandedSettingsPanelWidth
        : _settingsPanelCollapsedWidth;
    final dialogRadius = BorderRadius.circular(
      FabTabBarTokens.previewAcademyInputSheetRadius,
    );
    final currentUrl = _currentPdfUrl.trim();
    final uri = currentUrl.isEmpty ? null : Uri.tryParse(currentUrl);
    final zoomPercent = _viewerController.isReady
        ? (_viewerController.currentZoom * 100).round()
        : 100;
    return SizedBox(
      width: widget.expandedDialogSize.width,
      height: widget.expandedDialogSize.height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: kDlgBg,
          borderRadius: dialogRadius,
          boxShadow: const [
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 32,
              offset: Offset(0, 12),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: dialogRadius,
          child: ColoredBox(
            color: kDlgBg,
            child: Padding(
              padding: _dialogContentPadding,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                widget.titleText,
                                style: const TextStyle(
                                  color: Color(0xFFEAF2F2),
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            IconButton(
                              tooltip: '닫기',
                              onPressed: _attemptClose,
                              icon: const Icon(
                                Icons.close,
                                color: Color(0xFF9FB3B3),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF151E24),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: const Color(0xFF223131),
                                ),
                              ),
                              child: Text(
                                _pageCount > 0
                                    ? '$_pageNumber / $_pageCount'
                                    : '- / -',
                                style: const TextStyle(
                                  color: Color(0xFF9FB3B3),
                                  fontSize: 12.4,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            const Spacer(),
                            IconButton(
                              tooltip: '축소',
                              onPressed: () => _zoomByFactor(0.85),
                              icon: const Icon(
                                Icons.remove,
                                color: Color(0xFF9FB3B3),
                              ),
                            ),
                            Text(
                              '$zoomPercent%',
                              style: const TextStyle(
                                color: Color(0xFF9FB3B3),
                                fontSize: 12.6,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            IconButton(
                              tooltip: '확대',
                              onPressed: () => _zoomByFactor(1.15),
                              icon: const Icon(
                                Icons.add,
                                color: Color(0xFF9FB3B3),
                              ),
                            ),
                            IconButton(
                              tooltip: '화면 맞춤',
                              onPressed: _resetZoomToFit,
                              icon: const Icon(
                                Icons.fit_screen_rounded,
                                color: Color(0xFF9FB3B3),
                              ),
                            ),
                            IconButton(
                              tooltip: '인쇄',
                              onPressed:
                                  uri == null ||
                                      _isPrintingPdf ||
                                      widget.onPrintRequested == null
                                  ? null
                                  : _printCurrentPdf,
                              icon: _isPrintingPdf
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.print_rounded,
                                      color: Color(0xFF9FB3B3),
                                    ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              color: kDlgPanelBg,
                              child: uri == null
                                  ? Center(
                                      child: Text(
                                        (_previewFailureMessage ??
                                                '유효한 PDF URL이 아닙니다.')
                                            .trim(),
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          color: Color(0xFF9FB3B3),
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    )
                                  : PdfViewer.uri(
                                      uri,
                                      key: ValueKey(
                                        'preview_${_viewerRevision}_${uri.toString()}',
                                      ),
                                      controller: _viewerController,
                                      params: PdfViewerParams(
                                        backgroundColor: kDlgPanelBg,
                                        margin: 10,
                                        layoutPages: _layoutTwoPageVertical,
                                        pageAnchor: PdfPageAnchor.center,
                                        pageAnchorEnd: PdfPageAnchor.center,
                                        panEnabled: true,
                                        scaleEnabled: true,
                                        panAxis: PanAxis.free,
                                        pageDropShadow: null,
                                        maxScale: _maxScale,
                                        minScale: _minScale,
                                        useAlternativeFitScaleAsMinScale: false,
                                        calculateInitialZoom:
                                            (
                                              document,
                                              controller,
                                              fitZoom,
                                              coverZoom,
                                            ) {
                                              _fitZoom ??= fitZoom;
                                              return fitZoom;
                                            },
                                        onViewerReady: (document, controller) {
                                          if (!mounted) return;
                                          setState(() {
                                            _pageCount = document.pages.length;
                                            _pageNumber =
                                                (controller.pageNumber ?? 1)
                                                    .clamp(1, 9999);
                                          });
                                        },
                                        onPageChanged: (page) {
                                          if (!mounted || page == null) {
                                            return;
                                          }
                                          setState(() {
                                            _pageNumber = page;
                                          });
                                        },
                                        loadingBannerBuilder:
                                            (
                                              context,
                                              bytesDownloaded,
                                              totalBytes,
                                            ) {
                                              return const Center(
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                    ),
                                              );
                                            },
                                        errorBannerBuilder:
                                            (
                                              context,
                                              error,
                                              stackTrace,
                                              documentRef,
                                            ) {
                                              return Center(
                                                child: Text(
                                                  '미리보기 PDF를 열 수 없습니다: $error',
                                                  style: const TextStyle(
                                                    color: Color(0xFF9FB3B3),
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                              );
                                            },
                                      ),
                                    ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: _settingsPanelGap),
                  AnimatedContainer(
                    duration: FabTabBarTokens
                        .previewAcademyInputSheetTransitionDuration,
                    curve: Curves.easeOutCubic,
                    width: settingsPanelWidth,
                    child: Container(
                      padding: _settingsPanelExpanded
                          ? const EdgeInsets.fromLTRB(10, 10, 10, 10)
                          : EdgeInsets.zero,
                      decoration: BoxDecoration(
                        color: panelCardBackground,
                        borderRadius: BorderRadius.circular(
                          FabTabBarTokens.previewAcademyGroupedCardRadius,
                        ),
                        border: panelCardBorder,
                      ),
                      child: Column(
                        children: [
                          if (_settingsPanelExpanded) ...[
                            Row(
                              children: [
                                IconButton(
                                  tooltip: '설정 접기',
                                  onPressed: () => setState(
                                    () => _settingsPanelExpanded = false,
                                  ),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                    minWidth: 36,
                                    minHeight: 36,
                                  ),
                                  icon: const Icon(Icons.chevron_right),
                                  color: panelStyle.icon,
                                ),
                                Expanded(
                                  child: Text(
                                    '설정',
                                    style: TextStyle(
                                      color: panelStyle.title,
                                      fontSize: 14.2,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                FilledButton.tonalIcon(
                                  onPressed: _isRefreshing
                                      ? null
                                      : _refreshPreview,
                                  style: FilledButton.styleFrom(
                                    backgroundColor: panelButtonBackground,
                                    foregroundColor:
                                        panelStyle.changeButtonText,
                                    disabledBackgroundColor: panelStyle.divider,
                                    disabledForegroundColor: panelStyle.hint,
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  icon: _isRefreshing
                                      ? const SizedBox(
                                          width: 14,
                                          height: 14,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(
                                          Icons.refresh_rounded,
                                          size: 16,
                                        ),
                                  label: const Text('새로고침'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            Expanded(
                              child: SingleChildScrollView(
                                child: Column(
                                  children: [
                                    _buildSectionCard(
                                      title: '타이틀',
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          if (widget.isGyeongsinTemplate ||
                                              widget.isNeunginTemplate ||
                                              widget.isDaeryunTemplate ||
                                              widget.isDongdoTemplate ||
                                              widget.isSoseonTemplate ||
                                              widget.isOseongTemplate ||
                                              widget.isJeonghwaTemplate ||
                                              widget.isHwanggeumTemplate)
                                            _buildGyeongsinInfoEditor()
                                          else
                                            _buildCoverTextField(
                                              label:
                                                  '제목 페이지 상단 문구 (모든 제목 페이지 공통)',
                                              controller:
                                                  _titlePageTopTextController,
                                              hintText:
                                                  _defaultTitlePageTopText,
                                            ),
                                          if (widget.isAssignmentTemplate)
                                            _buildCoverTextField(
                                              label:
                                                  '과제목표 (제목 옆 가운데·회색, 기본 "다시 풀기")',
                                              controller:
                                                  _titlePageGoalTextController,
                                              hintText:
                                                  _defaultTitlePageGoalText,
                                            ),
                                          if (!widget.isGyeongsinTemplate &&
                                              !widget.isNeunginTemplate &&
                                              !widget.isDaeryunTemplate &&
                                              !widget.isDongdoTemplate &&
                                              !widget.isSoseonTemplate &&
                                              !widget.isOseongTemplate &&
                                              !widget.isJeonghwaTemplate &&
                                              !widget.isHwanggeumTemplate)
                                            _buildTitleSwitchTile(
                                              label: '학원 로고',
                                              description:
                                                  '모의고사형 제목 페이지에 학원 로고를 표시합니다.',
                                              value: _includeAcademyLogo,
                                              onChanged: (value) {
                                                setState(() {
                                                  _includeAcademyLogo = value;
                                                });
                                              },
                                            ),
                                          if (!widget.isDaeryunTemplate &&
                                              !widget.isDongdoTemplate) ...[
                                            _buildTitleSwitchTile(
                                              label: '표지',
                                              description:
                                                  widget.isNeunginTemplate
                                                  ? 'ON 시 능인중 문제지 표지를 앞에 추가합니다.'
                                                  : (widget.isSoseonTemplate
                                                        ? 'ON 시 소선여중 문제지 표지를 앞에 추가합니다.'
                                                        : (widget.isOseongTemplate
                                                              ? 'ON 시 오성중 문제지 표지를 앞에 추가합니다.'
                                                              : (widget.isJeonghwaTemplate
                                                                    ? 'ON 시 정화중 문제지 표지를 앞에 추가합니다.'
                                                                    : (widget.isHwanggeumTemplate
                                                                          ? 'ON 시 황금중 문제지 표지를 앞에 추가합니다.'
                                                                          : (widget.isGyeongsinTemplate
                                                                                ? 'ON 시 경신중 [문제지 표지]를 앞에 추가합니다.'
                                                                                : 'ON 시 맨 앞에 표지 페이지를 추가합니다.'))))),
                                              value: _includeCoverPage,
                                              onChanged: (value) {
                                                setState(() {
                                                  _includeCoverPage = value;
                                                });
                                              },
                                            ),
                                            if (_includeCoverPage &&
                                                _coverPageSheetCount.isOdd)
                                              _buildTitleSwitchTile(
                                                label: '표지 뒤 빈 페이지',
                                                description:
                                                    '홀수 쪽 표지 뒷면에 빈 페이지를 넣습니다. (모의고사·경신중 기본 ON, 외 학교 기본 OFF)',
                                                value: _includeCoverBlankPage,
                                                onChanged: (value) {
                                                  setState(() {
                                                    _includeCoverBlankPage =
                                                        value;
                                                  });
                                                },
                                              ),
                                          ],
                                          _buildTitleSwitchTile(
                                            label: '점수',
                                            description:
                                                '문항 끝에 [N점] 형식으로 배점을 표시합니다.',
                                            value: _includeQuestionScore,
                                            trailingAction: IconButton(
                                              onPressed:
                                                  _questionScoreEntries.isEmpty
                                                  ? null
                                                  : _openQuestionScoreSettingsDialog,
                                              tooltip: '문항별 점수 설정',
                                              icon: const Icon(
                                                Icons.tune_rounded,
                                              ),
                                              iconSize: 18,
                                              color: _textPrimary,
                                              disabledColor: _textMuted,
                                              visualDensity:
                                                  VisualDensity.compact,
                                              style: IconButton.styleFrom(
                                                backgroundColor: const Color(
                                                  0xFF1B252B,
                                                ),
                                                foregroundColor: _textPrimary,
                                                disabledBackgroundColor:
                                                    const Color(0xFF162026),
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                ),
                                              ),
                                            ),
                                            onChanged: (value) {
                                              setState(() {
                                                _includeQuestionScore = value;
                                              });
                                            },
                                          ),
                                          _buildTitleSwitchTile(
                                            label: '빠른정답',
                                            description:
                                                '정답지(빠른정답) 페이지를 포함합니다.',
                                            value: _includeAnswerSheet,
                                            onChanged: (value) {
                                              setState(() {
                                                _includeAnswerSheet = value;
                                              });
                                            },
                                          ),
                                          _buildTitleSwitchTile(
                                            label: '해설',
                                            description: '해설/검수 메모 페이지를 포함합니다.',
                                            value: _includeExplanation,
                                            onChanged: (value) {
                                              setState(() {
                                                _includeExplanation = value;
                                              });
                                            },
                                          ),
                                          if (_includeCoverPage &&
                                              !widget.isGyeongsinTemplate &&
                                              !widget.isNeunginTemplate &&
                                              !widget.isDaeryunTemplate &&
                                              !widget.isDongdoTemplate &&
                                              !widget.isSoseonTemplate &&
                                              !widget.isOseongTemplate &&
                                              !widget.isJeonghwaTemplate &&
                                              !widget.isHwanggeumTemplate)
                                            _buildCoverPageTextEditor(),
                                          const SizedBox(height: 4),
                                          Text(
                                            '중앙 타이틀 입력은 페이지 카드 하단의 `제목` 편집에서 페이지별로 설정합니다.\n1페이지는 기본 제목 페이지이며, 제목 페이지로 지정된 카드에서 타이틀/부제를 각각 입력할 수 있습니다.',
                                            style: TextStyle(
                                              color: panelStyle.hint,
                                              fontSize: 12.0,
                                              fontWeight: FontWeight.w600,
                                              height: 1.38,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                    _buildSectionCard(
                                      title: '문제와 답안',
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          _buildCoverTextField(
                                            label: '제한시간 (저장/복원용, PDF 미표시)',
                                            controller: _timeLimitController,
                                            hintText: '예: 100분',
                                          ),
                                          Text(
                                            '현재 설정: 로고 ${_includeAcademyLogo ? 'ON' : 'OFF'} · 점수 ${_includeQuestionScore ? 'ON' : 'OFF'} · 빠른정답 ${_includeAnswerSheet ? 'ON' : 'OFF'} · 해설 ${_includeExplanation ? 'ON' : 'OFF'}',
                                            style: TextStyle(
                                              color: panelStyle.hint,
                                              fontSize: 12.2,
                                              fontWeight: FontWeight.w600,
                                              height: 1.35,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                    _buildSectionCard(
                                      title: '레이아웃',
                                      child: _buildPageLayoutCards(),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            _buildCreateAssignmentButton(),
                            const SizedBox(height: 8),
                            _buildSaveSettingsButtons(),
                            const SizedBox(height: 8),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton.icon(
                                onPressed:
                                    (widget.onGeneratePdfRequested == null ||
                                        _isGeneratingPdf ||
                                        _isRefreshing ||
                                        _isSavingSettings ||
                                        _isCreatingAssignment)
                                    ? null
                                    : _generatePdf,
                                style: FilledButton.styleFrom(
                                  backgroundColor: const Color(0xFF173C36),
                                  foregroundColor: const Color(0xFFC7F2D8),
                                  disabledBackgroundColor: const Color(
                                    0xFF152A27,
                                  ),
                                  disabledForegroundColor: const Color(
                                    0xFF7CA39A,
                                  ),
                                  minimumSize: const Size.fromHeight(42),
                                  shape: const StadiumBorder(),
                                ),
                                icon: _isGeneratingPdf
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(
                                        Icons.picture_as_pdf,
                                        size: 18,
                                      ),
                                label: const Text(
                                  'PDF 생성',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ),
                          ] else ...[
                            IconButton(
                              tooltip: '설정 펼치기',
                              onPressed: () =>
                                  setState(() => _settingsPanelExpanded = true),
                              icon: const Icon(Icons.chevron_left),
                              color: panelStyle.icon,
                            ),
                            const Expanded(child: SizedBox.shrink()),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
