import 'dart:math' as math;
import 'dart:convert';
import 'dart:ui';

import 'package:crypto/crypto.dart';

import '../../../services/learning_problem_bank_service.dart';

const List<String> kLearningProblemTemplateOptions = <String>[
  '내신형',
  '수능형',
  '모의고사형',
];

const List<String> kLearningProblemPaperOptions = <String>['A4', 'B4', '8절'];

const List<String> kLearningProblemQuestionModeOptions = <String>[
  '원본',
  '객관식',
  '주관식',
  '서술형',
];

const List<String> kLearningProblemLayoutColumnOptions = <String>['1단', '2단'];

const Map<String, List<int>> kLearningProblemMaxPerPageOptionsByLayout =
    <String, List<int>>{
  '1단': <int>[1, 2, 3, 4],
  '2단': <int>[1, 2, 4, 6, 8],
};

const List<String> kLearningProblemFontFamilyOptions = <String>[
  '기본',
  'HCRBatang',
  'KakaoSmallSans',
  'NanumGothic',
  'KoPubWorldBatangPro',
];

const List<String> kLearningProblemFontSizeOptions = <String>[
  '기본',
  '10',
  '10.5',
  '11',
  '12',
  '13',
  '14',
];

const String kLearningQuestionModeOriginal = 'original';
const String kLearningQuestionModeObjective = 'objective';
const String kLearningQuestionModeSubjective = 'subjective';
const String kLearningQuestionModeEssay = 'essay';
final String kLearningRenderConfigVersion =
    'pb_render_v31h_mock_template_header5';

class LearningProblemLayoutTuning {
  const LearningProblemLayoutTuning({
    required this.pageMargin,
    required this.columnGap,
    required this.questionGap,
    required this.numberLaneWidth,
    required this.numberGap,
    required this.hangingIndent,
    required this.lineHeight,
    required this.choiceSpacing,
  });

  factory LearningProblemLayoutTuning.defaults() {
    return const LearningProblemLayoutTuning(
      pageMargin: 46,
      columnGap: 18,
      questionGap: 30,
      numberLaneWidth: 26,
      numberGap: 6,
      hangingIndent: 22,
      lineHeight: 15.4,
      choiceSpacing: 2.2,
    );
  }

  final double pageMargin;
  final double columnGap;
  final double questionGap;
  final double numberLaneWidth;
  final double numberGap;
  final double hangingIndent;
  final double lineHeight;
  final double choiceSpacing;

  LearningProblemLayoutTuning copyWith({
    double? pageMargin,
    double? columnGap,
    double? questionGap,
    double? numberLaneWidth,
    double? numberGap,
    double? hangingIndent,
    double? lineHeight,
    double? choiceSpacing,
  }) {
    return LearningProblemLayoutTuning(
      pageMargin: pageMargin ?? this.pageMargin,
      columnGap: columnGap ?? this.columnGap,
      questionGap: questionGap ?? this.questionGap,
      numberLaneWidth: numberLaneWidth ?? this.numberLaneWidth,
      numberGap: numberGap ?? this.numberGap,
      hangingIndent: hangingIndent ?? this.hangingIndent,
      lineHeight: lineHeight ?? this.lineHeight,
      choiceSpacing: choiceSpacing ?? this.choiceSpacing,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'pageMargin': pageMargin,
      'columnGap': columnGap,
      'questionGap': questionGap,
      'numberLaneWidth': numberLaneWidth,
      'numberGap': numberGap,
      'hangingIndent': hangingIndent,
      'lineHeight': lineHeight,
      'choiceSpacing': choiceSpacing,
    };
  }
}

class LearningProblemFigureQuality {
  const LearningProblemFigureQuality({
    required this.targetDpi,
    required this.minDpi,
  });

  factory LearningProblemFigureQuality.defaults() {
    return const LearningProblemFigureQuality(
      targetDpi: 450,
      minDpi: 300,
    );
  }

  final int targetDpi;
  final int minDpi;

  LearningProblemFigureQuality copyWith({
    int? targetDpi,
    int? minDpi,
  }) {
    return LearningProblemFigureQuality(
      targetDpi: targetDpi ?? this.targetDpi,
      minDpi: minDpi ?? this.minDpi,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'targetDpi': targetDpi,
      'minDpi': minDpi,
    };
  }
}

class LearningProblemExportSettings {
  const LearningProblemExportSettings({
    required this.templateLabel,
    required this.paperLabel,
    required this.questionModeLabel,
    required this.layoutColumnLabel,
    required this.maxQuestionsPerPageLabel,
    required this.fontFamilyLabel,
    required this.fontSizeLabel,
    required this.layoutTuning,
    required this.figureQuality,
    required this.includeAnswerSheet,
    required this.includeExplanation,
  });

  factory LearningProblemExportSettings.initial() {
    return LearningProblemExportSettings(
      templateLabel: '내신형',
      paperLabel: 'A4',
      questionModeLabel: '원본',
      layoutColumnLabel: '1단',
      maxQuestionsPerPageLabel: '많이',
      fontFamilyLabel: 'KoPubWorldBatangPro',
      fontSizeLabel: '기본',
      layoutTuning: LearningProblemLayoutTuning.defaults(),
      figureQuality: LearningProblemFigureQuality.defaults(),
      includeAnswerSheet: true,
      includeExplanation: false,
    );
  }

  final String templateLabel;
  final String paperLabel;
  final String questionModeLabel;
  final String layoutColumnLabel;
  final String maxQuestionsPerPageLabel;
  final String fontFamilyLabel;
  final String fontSizeLabel;
  final LearningProblemLayoutTuning layoutTuning;
  final LearningProblemFigureQuality figureQuality;
  final bool includeAnswerSheet;
  final bool includeExplanation;

  int get layoutColumnCount => layoutColumnsToCount(layoutColumnLabel);

  List<int> get maxQuestionsPerPageOptions =>
      maxQuestionsPerPageOptionsOf(layoutColumnLabel);

  int get maxQuestionsPerPageCount {
    if (maxQuestionsPerPageLabel.trim() == '많이') return 99;
    final parsed = int.tryParse(maxQuestionsPerPageLabel);
    if (parsed != null && maxQuestionsPerPageOptions.contains(parsed)) {
      return parsed;
    }
    return maxQuestionsPerPageOptions.last;
  }

  String get templateProfile => templateToProfile(templateLabel);
  String get questionModeValue => questionModeToValue(questionModeLabel);
  Size get paperPointSize => paperPointSizeOf(paperLabel);
  String get resolvedFontFamily {
    final safe = fontFamilyLabel.trim();
    if (safe.isEmpty || safe == '기본') return 'KoPubWorldBatangPro';
    return safe;
  }

  double get resolvedFontSize {
    final safe = fontSizeLabel.trim();
    final parsed = double.tryParse(safe);
    if (parsed == null || parsed <= 0) return 11.0;
    return parsed;
  }

  Map<String, dynamic> toRenderConfig({
    required List<String> selectedQuestionIdsOrdered,
    required Map<String, String> questionModeByQuestionId,
  }) {
    final orderedIds = selectedQuestionIdsOrdered
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    final modeMap = <String, String>{};
    for (final id in orderedIds) {
      final mode = questionModeByQuestionId[id];
      if (mode == null || mode.trim().isEmpty) continue;
      modeMap[id] = mode.trim();
    }
    return <String, dynamic>{
      'renderConfigVersion': kLearningRenderConfigVersion,
      'templateProfile': templateProfile,
      'paperSize': paperLabel.trim(),
      'font': <String, dynamic>{
        'family': resolvedFontFamily,
        'size': resolvedFontSize,
      },
      'layoutColumns': layoutColumnCount,
      'maxQuestionsPerPage': maxQuestionsPerPageCount,
      'questionMode': questionModeValue,
      'layoutTuning': layoutTuning.toJson(),
      'figureQuality': figureQuality.toJson(),
      'questionModeByQuestionId': modeMap,
      'selectedQuestionIdsOrdered': orderedIds,
    };
  }

  LearningProblemExportSettings copyWith({
    String? templateLabel,
    String? paperLabel,
    String? questionModeLabel,
    String? layoutColumnLabel,
    String? maxQuestionsPerPageLabel,
    String? fontFamilyLabel,
    String? fontSizeLabel,
    LearningProblemLayoutTuning? layoutTuning,
    LearningProblemFigureQuality? figureQuality,
    bool? includeAnswerSheet,
    bool? includeExplanation,
  }) {
    return LearningProblemExportSettings(
      templateLabel: templateLabel ?? this.templateLabel,
      paperLabel: paperLabel ?? this.paperLabel,
      questionModeLabel: questionModeLabel ?? this.questionModeLabel,
      layoutColumnLabel: layoutColumnLabel ?? this.layoutColumnLabel,
      maxQuestionsPerPageLabel:
          maxQuestionsPerPageLabel ?? this.maxQuestionsPerPageLabel,
      fontFamilyLabel: fontFamilyLabel ?? this.fontFamilyLabel,
      fontSizeLabel: fontSizeLabel ?? this.fontSizeLabel,
      layoutTuning: layoutTuning ?? this.layoutTuning,
      figureQuality: figureQuality ?? this.figureQuality,
      includeAnswerSheet: includeAnswerSheet ?? this.includeAnswerSheet,
      includeExplanation: includeExplanation ?? this.includeExplanation,
    );
  }
}

class LearningProblemLayoutPreviewPage {
  const LearningProblemLayoutPreviewPage({
    required this.leftColumnSlots,
    required this.rightColumnSlots,
    required this.rowCount,
    required this.leftSlotCount,
    required this.rightSlotCount,
  });

  final List<LearningProblemLayoutSlot> leftColumnSlots;
  final List<LearningProblemLayoutSlot> rightColumnSlots;
  final int rowCount;
  final int leftSlotCount;
  final int rightSlotCount;
}

class LearningProblemLayoutSlot {
  const LearningProblemLayoutSlot({
    this.question,
    this.span = 1,
    this.hidden = false,
  });

  const LearningProblemLayoutSlot.empty()
      : question = null,
        span = 1,
        hidden = false;

  const LearningProblemLayoutSlot.hidden()
      : question = null,
        span = 1,
        hidden = true;

  final LearningProblemQuestion? question;
  final int span;
  final bool hidden;
}

String templateToProfile(String template) {
  switch (template.trim()) {
    case '수능형':
      return 'csat';
    case '모의고사형':
      return 'mock';
    case '내신형':
    default:
      return 'naesin';
  }
}

String questionModeToValue(String label) {
  switch (label.trim()) {
    case '객관식':
      return kLearningQuestionModeObjective;
    case '주관식':
      return kLearningQuestionModeSubjective;
    case '서술형':
      return kLearningQuestionModeEssay;
    case '원본':
    default:
      return kLearningQuestionModeOriginal;
  }
}

String questionModeLabelOf(String mode) {
  switch (mode.trim()) {
    case kLearningQuestionModeObjective:
      return '객관식';
    case kLearningQuestionModeSubjective:
      return '주관식';
    case kLearningQuestionModeEssay:
      return '서술형';
    case kLearningQuestionModeOriginal:
    default:
      return '원본';
  }
}

bool allowEssayOf(LearningProblemQuestion question) {
  return question.meta['allow_essay'] == true ||
      question.questionType.contains('서술');
}

String originalQuestionModeOf(LearningProblemQuestion question) {
  final type = question.questionType.trim();
  if (type.contains('서술')) return kLearningQuestionModeEssay;
  if (type.contains('객관식')) return kLearningQuestionModeObjective;
  if (type.contains('주관식')) return kLearningQuestionModeSubjective;
  if (question.allowObjective && !question.allowSubjective) {
    return kLearningQuestionModeObjective;
  }
  if (!question.allowObjective && question.allowSubjective) {
    return kLearningQuestionModeSubjective;
  }
  if (question.effectiveChoices.length >= 2) {
    return kLearningQuestionModeObjective;
  }
  return kLearningQuestionModeSubjective;
}

List<String> selectableQuestionModesOf(LearningProblemQuestion question) {
  final original = originalQuestionModeOf(question);
  final out = <String>[
    if (question.allowObjective || original == kLearningQuestionModeObjective)
      kLearningQuestionModeObjective,
    if (question.allowSubjective || original == kLearningQuestionModeSubjective)
      kLearningQuestionModeSubjective,
    if (allowEssayOf(question) || original == kLearningQuestionModeEssay)
      kLearningQuestionModeEssay,
  ];
  if (out.isEmpty) {
    out.add(original);
  }
  return out.toSet().toList(growable: false);
}

String normalizeQuestionModeSelection(
  LearningProblemQuestion question,
  String? selectedMode, {
  String fallbackMode = kLearningQuestionModeOriginal,
}) {
  final allowed = selectableQuestionModesOf(question);
  final preferred = (selectedMode ?? '').trim();
  if (preferred.isNotEmpty && allowed.contains(preferred)) return preferred;
  if (fallbackMode != kLearningQuestionModeOriginal &&
      allowed.contains(fallbackMode)) {
    return fallbackMode;
  }
  final original = originalQuestionModeOf(question);
  if (allowed.contains(original)) return original;
  return allowed.first;
}

String effectiveQuestionModeOf(
  LearningProblemQuestion question, {
  required Map<String, String> questionModeByQuestionId,
  required String fallbackMode,
}) {
  return normalizeQuestionModeSelection(
    question,
    questionModeByQuestionId[question.id],
    fallbackMode: fallbackMode,
  );
}

int layoutColumnsToCount(String label) => label.trim() == '2단' ? 2 : 1;

List<int> maxQuestionsPerPageOptionsOf(String layoutLabel) {
  final options = kLearningProblemMaxPerPageOptionsByLayout[layoutLabel];
  if (options != null && options.isNotEmpty) return options;
  return kLearningProblemMaxPerPageOptionsByLayout['1단']!;
}

Size paperPointSizeOf(String paperLabel) {
  switch (paperLabel.trim()) {
    case 'B4':
      return const Size(729, 1032);
    case '8절':
      return const Size(774, 1118);
    case 'A4':
    default:
      return const Size(595, 842);
  }
}

double questionSlotHeightForLayoutPreview({
  required int columns,
  required int rows,
}) {
  if (columns == 2) {
    if (rows <= 1) return 240;
    if (rows == 2) return 210;
    if (rows == 3) return 168;
    return 132;
  }
  if (rows <= 1) return 260;
  if (rows == 2) return 210;
  if (rows == 3) return 166;
  return 128;
}

List<LearningProblemLayoutPreviewPage> buildQuestionLayoutPreviewPages(
  List<LearningProblemQuestion> selectedQuestions, {
  required LearningProblemExportSettings settings,
  Map<String, String> questionModeByQuestionId = const <String, String>{},
}) {
  final pages = <LearningProblemLayoutPreviewPage>[];
  if (selectedQuestions.isEmpty) return pages;
  final maxPerPage = settings.maxQuestionsPerPageCount.clamp(1, 8);
  final columns = settings.layoutColumnCount;
  final adaptiveTwoByTwoSpan = columns == 2 && maxPerPage == 4;
  final leftSlotCount = columns == 1 ? maxPerPage : (maxPerPage / 2).ceil();
  final rightSlotCount = columns == 1 ? 0 : (maxPerPage - leftSlotCount);
  final rowCount =
      columns == 1 ? leftSlotCount : math.max(leftSlotCount, rightSlotCount);
  var cursor = 0;

  while (cursor < selectedQuestions.length) {
    final leftSlots = List<LearningProblemLayoutSlot>.generate(
      leftSlotCount,
      (_) => const LearningProblemLayoutSlot.empty(),
      growable: false,
    );
    final rightSlots = List<LearningProblemLayoutSlot>.generate(
      rightSlotCount,
      (_) => const LearningProblemLayoutSlot.empty(),
      growable: false,
    );
    var leftCursor = 0;
    var rightCursor = 0;
    var placedAny = false;

    while (cursor < selectedQuestions.length) {
      final original = selectedQuestions[cursor];
      final mode = effectiveQuestionModeOf(
        original,
        questionModeByQuestionId: questionModeByQuestionId,
        fallbackMode: settings.questionModeValue,
      );
      final previewQuestion = questionForLayoutPreviewMode(
        original,
        mode,
      );
      final desiredSpan = _estimateSlotSpanForQuestion(
        previewQuestion,
        rowCount: rowCount,
        twoByTwoAdaptiveSpan: adaptiveTwoByTwoSpan,
      );
      var placed = false;

      if (leftCursor < leftSlotCount) {
        final leftRemain = leftSlotCount - leftCursor;
        if (desiredSpan <= leftRemain || leftCursor == 0) {
          final useSpan = desiredSpan <= leftRemain ? desiredSpan : leftRemain;
          _placeQuestionIntoSlots(leftSlots, leftCursor, original, useSpan);
          leftCursor += useSpan;
          placed = true;
        } else {
          leftCursor = leftSlotCount;
        }
      }

      if (!placed && rightSlotCount > 0 && rightCursor < rightSlotCount) {
        final rightRemain = rightSlotCount - rightCursor;
        if (desiredSpan <= rightRemain || rightCursor == 0) {
          final useSpan =
              desiredSpan <= rightRemain ? desiredSpan : rightRemain;
          _placeQuestionIntoSlots(rightSlots, rightCursor, original, useSpan);
          rightCursor += useSpan;
          placed = true;
        } else {
          rightCursor = rightSlotCount;
        }
      }

      if (!placed) break;

      placedAny = true;
      cursor += 1;
      final pageFilled = leftCursor >= leftSlotCount &&
          (rightSlotCount == 0 || rightCursor >= rightSlotCount);
      if (pageFilled) break;
    }

    if (!placedAny) {
      _placeQuestionIntoSlots(
        leftSlots,
        0,
        selectedQuestions[cursor],
        leftSlotCount > 0 ? 1 : 0,
      );
      cursor += 1;
    }

    pages.add(
      LearningProblemLayoutPreviewPage(
        leftColumnSlots: leftSlots,
        rightColumnSlots: rightSlots,
        rowCount: rowCount,
        leftSlotCount: leftSlotCount,
        rightSlotCount: rightSlotCount,
      ),
    );
  }
  return pages;
}

LearningProblemQuestion questionForLayoutPreviewMode(
  LearningProblemQuestion question,
  String questionMode,
) {
  if (questionMode == kLearningQuestionModeObjective) {
    final choices = question.effectiveChoices;
    return question.copyWith(
      questionType: '객관식',
      choices: choices,
      objectiveChoices: choices,
    );
  }
  if (questionMode == kLearningQuestionModeSubjective) {
    return question.copyWith(
      questionType: '주관식',
      choices: const <LearningProblemChoice>[],
      objectiveChoices: const <LearningProblemChoice>[],
    );
  }
  if (questionMode == kLearningQuestionModeEssay) {
    return question.copyWith(
      questionType: '서술형',
      choices: const <LearningProblemChoice>[],
      objectiveChoices: const <LearningProblemChoice>[],
    );
  }
  if (looksObjectiveInOriginalMode(question)) {
    final choices = question.effectiveChoices.isNotEmpty
        ? question.effectiveChoices
        : const <LearningProblemChoice>[];
    return question.copyWith(
      questionType: '객관식',
      choices: choices,
      objectiveChoices: choices,
    );
  }
  return question.copyWith(
    questionType: '주관식',
    choices: const <LearningProblemChoice>[],
    objectiveChoices: const <LearningProblemChoice>[],
  );
}

bool looksObjectiveInOriginalMode(LearningProblemQuestion question) {
  return question.effectiveChoices.length >= 2 ||
      question.questionType.contains('객관식');
}

String previewAnswerForMode(
  LearningProblemQuestion question,
  String questionMode,
) {
  if (questionMode == kLearningQuestionModeObjective) {
    return objectiveAnswerForPreview(question);
  }
  if (questionMode == kLearningQuestionModeSubjective ||
      questionMode == kLearningQuestionModeEssay) {
    return subjectiveAnswerForPreview(question);
  }
  if (looksObjectiveInOriginalMode(question)) {
    return objectiveAnswerForPreview(question);
  }
  return subjectiveAnswerForPreview(question);
}

String objectiveAnswerForPreview(LearningProblemQuestion question) {
  return _sanitizeAnswerText(
    question.objectiveAnswerKey.isNotEmpty
        ? question.objectiveAnswerKey
        : '${question.meta['objective_answer_key'] ?? question.meta['answer_key'] ?? ''}',
  );
}

String subjectiveAnswerForPreview(LearningProblemQuestion question) {
  final direct = _sanitizeAnswerText(
    question.subjectiveAnswer.isNotEmpty
        ? question.subjectiveAnswer
        : '${question.meta['subjective_answer'] ?? ''}',
  );
  if (direct.isNotEmpty) return direct;
  final objective = objectiveAnswerForPreview(question);
  if (objective.isEmpty) return '';
  final choices = question.effectiveChoices;
  return _subjectiveFromObjectiveChoiceText(objective, choices);
}

String explanationForPreview(LearningProblemQuestion question) {
  final raw = question.reviewerNotes.isNotEmpty
      ? question.reviewerNotes
      : '${question.meta['reviewer_notes'] ?? question.meta['explanation'] ?? ''}';
  final normalized = raw
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
  return normalized;
}

int _estimateSlotSpanForQuestion(
  LearningProblemQuestion previewQuestion, {
  required int rowCount,
  bool twoByTwoAdaptiveSpan = false,
}) {
  if (rowCount <= 1) return 1;
  final stemLength = previewQuestion.renderedStem.length;
  final choiceCount = previewQuestion.effectiveChoices.length;
  final figureCount = math.max(
    previewQuestion.orderedFigureAssets.length,
    previewQuestion.figureRefs.length,
  );
  final isVeryLong = stemLength >= 980;
  final hasHeavyFigure = figureCount >= 2;
  final hasDenseObjective = choiceCount >= 8 && stemLength >= 460;

  if (twoByTwoAdaptiveSpan) {
    return (isVeryLong || hasHeavyFigure || hasDenseObjective) ? 2 : 1;
  }
  if (isVeryLong || hasHeavyFigure || hasDenseObjective) {
    return rowCount >= 2 ? 2 : 1;
  }
  return 1;
}

void _placeQuestionIntoSlots(
  List<LearningProblemLayoutSlot> slots,
  int startIndex,
  LearningProblemQuestion question,
  int span,
) {
  if (slots.isEmpty || span <= 0) return;
  final safeStart = startIndex.clamp(0, slots.length - 1).toInt();
  final maxSpan = math.max(1, math.min(span, slots.length - safeStart));
  slots[safeStart] = LearningProblemLayoutSlot(
    question: question,
    span: maxSpan,
    hidden: false,
  );
  for (var i = 1; i < maxSpan; i += 1) {
    slots[safeStart + i] = const LearningProblemLayoutSlot.hidden();
  }
}

String _subjectiveFromObjectiveChoiceText(
  String answer,
  List<LearningProblemChoice> choices,
) {
  final normalized = _sanitizeAnswerText(answer);
  if (normalized.isEmpty) return '';
  if (choices.isEmpty) return normalized;

  final unitTokens = normalized
      .split(RegExp(r'[,\s/]+'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList(growable: false);
  if (unitTokens.isEmpty) return normalized;

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
    converted.add(token);
  }
  return _sanitizeAnswerText(converted.join(', '));
}

int? _answerTokenToChoiceIndex(String token) {
  const circled = <String, int>{
    '①': 0,
    '②': 1,
    '③': 2,
    '④': 3,
    '⑤': 4,
    '⑥': 5,
    '⑦': 6,
    '⑧': 7,
    '⑨': 8,
    '⑩': 9,
  };
  final trimmed = token.trim();
  if (trimmed.isEmpty) return null;
  final circledIdx = circled[trimmed];
  if (circledIdx != null) return circledIdx;
  final numeric = int.tryParse(trimmed.replaceAll(RegExp(r'[^0-9]'), ''));
  if (numeric == null || numeric <= 0) return null;
  return numeric - 1;
}

String _sanitizeAnswerText(String input) {
  return input
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'[,/]\s*[,/]+'), ', ')
      .trim();
}

String _normalizePreviewLine(String raw) {
  return raw.replaceAll(RegExp(r'\s+'), ' ').trim();
}

String buildLearningRenderHash({
  required LearningProblemExportSettings settings,
  required List<String> selectedQuestionIdsOrdered,
  required Map<String, String> questionModeByQuestionId,
}) {
  final renderConfig = settings.toRenderConfig(
    selectedQuestionIdsOrdered: selectedQuestionIdsOrdered,
    questionModeByQuestionId: questionModeByQuestionId,
  );
  final canonicalJson = _canonicalJsonEncode(renderConfig);
  return sha256.convert(utf8.encode(canonicalJson)).toString();
}

String _canonicalJsonEncode(dynamic value) {
  return jsonEncode(_canonicalizeJsonValue(value));
}

dynamic _canonicalizeJsonValue(dynamic value) {
  if (value is Map) {
    final sortedKeys = value.keys.map((e) => '$e').toList(growable: false)
      ..sort();
    final out = <String, dynamic>{};
    for (final key in sortedKeys) {
      out[key] = _canonicalizeJsonValue(value[key]);
    }
    return out;
  }
  if (value is Iterable) {
    return value.map(_canonicalizeJsonValue).toList(growable: false);
  }
  return value;
}
