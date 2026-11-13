import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../../services/learning_problem_bank_service.dart';
import '../../design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';
import '../models/problem_bank_export_models.dart';

const double _kPreviewHorizontalInset = 8;
const double _kPreviewBorderRadius = 10;
const double _kPreviewBorderWidth = 1.4;
const double _kPreviewHeight = 222;
const double _kPreviewOverflowThreshold = 14;
const double _kPreviewExpandBarHeight = 28;
// 헤더↔썸네일 간격: 12 → 9.6 → 추가 20% 축소 ≈ 7.68
const double _kHeaderTopPadding = 6;
const double _kHeaderPreviewGapHalf = 3.84;
const double _kContentBottomPadding = 4;
// 썸네일↔메타 간격: 기존 4의 2배 (줄간격 2배는 이 여백으로 표현)
const double _kMetaTopGap = 8;
const double _kMetaLineHeight = 1.3;
const double _kMetaLeftInset = _kPreviewHorizontalInset + 2;
const double _kReviewScoreChipHeight = 22;

/// 검수된 문항들의 사고·연산 점수 합. 기록이 하나도 없으면 둘 다 null.
({double? thinking, double? arithmetic}) problemBankReviewScoreTotal(
  Iterable<LearningProblemQuestion> questions,
) {
  var thinking = 0.0;
  var arithmetic = 0.0;
  var any = false;
  for (final question in questions) {
    final nextThinking = question.reviewThinkingScore;
    final nextArithmetic = question.reviewArithmeticScore;
    if (nextThinking == null || nextArithmetic == null) continue;
    thinking += nextThinking;
    arithmetic += nextArithmetic;
    any = true;
  }
  if (!any) return (thinking: null, arithmetic: null);
  return (thinking: thinking, arithmetic: arithmetic);
}

/// 썸네일 이미지·공통발문 위젯의 실제 높이를 캐시해 넘침 여부와 펼침 높이를 계산한다.
class ProblemBankPreviewSizeCache extends ChangeNotifier {
  ProblemBankPreviewSizeCache._();

  static final ProblemBankPreviewSizeCache instance =
      ProblemBankPreviewSizeCache._();

  final Map<String, double> _aspectRatioByUrl = <String, double>{};
  final Set<String> _resolvingUrls = <String>{};
  final Map<String, ({double width, double height})> _measuredByKey =
      <String, ({double width, double height})>{};
  bool _notifyScheduled = false;

  void _scheduleNotify() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _notifyScheduled = false;
      notifyListeners();
    });
  }

  void recordAspectRatio(String url, double widthOverHeight) {
    final trimmed = url.trim();
    if (trimmed.isEmpty || widthOverHeight <= 0) return;
    final previous = _aspectRatioByUrl[trimmed];
    if (previous != null && (previous - widthOverHeight).abs() <= 0.001) {
      return;
    }
    _aspectRatioByUrl[trimmed] = widthOverHeight;
    _scheduleNotify();
  }

  void resolveImage(String? url) {
    final trimmed = url?.trim() ?? '';
    if (trimmed.isEmpty ||
        _isPdfUrl(trimmed) ||
        _aspectRatioByUrl.containsKey(trimmed) ||
        _resolvingUrls.contains(trimmed)) {
      return;
    }
    _resolvingUrls.add(trimmed);
    final provider = NetworkImage(trimmed);
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (ImageInfo info, bool _) {
        _resolvingUrls.remove(trimmed);
        final w = info.image.width.toDouble();
        final h = info.image.height.toDouble();
        if (w > 0 && h > 0) {
          final nextRatio = w / h;
          final prev = _aspectRatioByUrl[trimmed];
          if (prev == null || (prev - nextRatio).abs() > 0.001) {
            _aspectRatioByUrl[trimmed] = nextRatio;
            _scheduleNotify();
          }
        }
        stream.removeListener(listener);
      },
      onError: (Object _, StackTrace? __) {
        _resolvingUrls.remove(trimmed);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
  }

  void recordMeasuredSize(String key, Size size) {
    final safeKey = key.trim();
    if (safeKey.isEmpty || size.width <= 0 || size.height <= 0) return;
    final prev = _measuredByKey[safeKey];
    if (prev != null &&
        (prev.width - size.width).abs() < 1.0 &&
        (prev.height - size.height).abs() < 1.0) {
      return;
    }
    _measuredByKey[safeKey] = (width: size.width, height: size.height);
    _scheduleNotify();
  }

  static bool _isPdfUrl(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    return path.endsWith('.pdf');
  }

  static double previewInnerWidthForCardWidth(double cardWidth) {
    return math.max(100.0, cardWidth - (_kPreviewHorizontalInset * 2) - 4.0);
  }

  double? naturalHeightFor({
    required String measureKey,
    required String? previewImageUrl,
    required double cardWidth,
  }) {
    final previewWidth = previewInnerWidthForCardWidth(cardWidth);
    final url = previewImageUrl?.trim() ?? '';
    if (url.isNotEmpty) {
      resolveImage(url);
      final ratio = _aspectRatioByUrl[url];
      if (ratio != null && ratio > 0) {
        return previewWidth / ratio;
      }
    }
    final safeKey = measureKey.trim();
    if (safeKey.isNotEmpty) {
      final measured = _measuredByKey[safeKey];
      if (measured != null && measured.width > 0 && measured.height > 0) {
        return measured.height * (previewWidth / measured.width);
      }
    }
    return null;
  }

  bool isOverflowing({
    required String measureKey,
    required String? previewImageUrl,
    required double cardWidth,
  }) {
    final natural = naturalHeightFor(
      measureKey: measureKey,
      previewImageUrl: previewImageUrl,
      cardWidth: cardWidth,
    );
    if (natural == null) return false;
    return natural > _kPreviewHeight + _kPreviewOverflowThreshold;
  }

  double extraHeightWhenExpanded({
    required String measureKey,
    required String? previewImageUrl,
    required double cardWidth,
    required bool expanded,
  }) {
    if (!expanded) return 0.0;
    final natural = naturalHeightFor(
      measureKey: measureKey,
      previewImageUrl: previewImageUrl,
      cardWidth: cardWidth,
    );
    if (natural == null ||
        natural <= _kPreviewHeight + _kPreviewOverflowThreshold) {
      return 0.0;
    }
    final targetPreviewHeight = natural + _kPreviewExpandBarHeight;
    return math.max(0.0, targetPreviewHeight - _kPreviewHeight);
  }
}

/// 독립형 세트문항(공통발문)과 단일 문항을 그리드 슬롯 단위로 묶는 모델.
class ProblemBankGridSlot<T> {
  const ProblemBankGridSlot({
    required this.key,
    required this.items,
    required this.questions,
    required this.isIndependentSet,
    this.commonStem = '',
    this.rangeLabel = '',
  });

  final String key;
  final List<T> items;
  final List<LearningProblemQuestion> questions;
  final bool isIndependentSet;
  final String commonStem;
  final String rangeLabel;

  T get firstItem => items.first;
  LearningProblemQuestion get firstQuestion => questions.first;

  LearningProblemQuestion get commonPreviewDonorQuestion {
    final figMarkerRe = RegExp(r'\[\s*(?:그림|도형|도표)\s*\]|\[\[PB_FIG_');
    if (figMarkerRe.hasMatch(commonStem)) {
      for (final q in questions) {
        final model = q.setModel;
        final commonAssets = model['common_figure_assets'];
        if (commonAssets is List && commonAssets.isNotEmpty) return q;
      }
      for (final q in questions) {
        if (q.figureAssets.isNotEmpty && !figMarkerRe.hasMatch(q.stem)) {
          return q;
        }
      }
    }
    return firstQuestion;
  }
}

String independentSetPreviewGroupKeyOf(LearningProblemQuestion q) =>
    'ind_set:${_independentSetIdentityOf(q)}';

String formatIndependentSetNumberToken(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  if (RegExp(r'^\d+$').hasMatch(trimmed)) {
    final parsed = int.tryParse(trimmed);
    if (parsed != null) {
      return parsed.toString().padLeft(2, '0');
    }
  }
  return trimmed;
}

String formatIndependentSetRangeLabel(List<LearningProblemQuestion> questions) {
  if (questions.isEmpty) return '';
  final firstQ = questions.first;
  final lastQ = questions.last;
  var firstRaw = firstQ.displayQuestionNumber;
  var lastRaw = lastQ.displayQuestionNumber;
  if (questions.length == 1) {
    final rf =
        '${firstQ.setModel['range_from'] ?? firstQ.setModel['rangeFrom'] ?? ''}'
            .trim();
    final rt =
        '${firstQ.setModel['range_to'] ?? firstQ.setModel['rangeTo'] ?? ''}'
            .trim();
    if (rf.isNotEmpty && rt.isNotEmpty) {
      firstRaw = rf;
      lastRaw = rt;
    }
  }
  final first = formatIndependentSetNumberToken(firstRaw);
  final last = formatIndependentSetNumberToken(lastRaw);
  if (first.isNotEmpty && last.isNotEmpty && first != last) {
    return '$first - $last';
  }
  return first.isNotEmpty ? first : last;
}

String _independentSetIdentityOf(LearningProblemQuestion q) {
  final docId = q.documentId.trim();
  final normStem = q.setCommonStem.replaceAll(RegExp(r'\s+'), ' ').trim();
  final deliverySetId =
      '${q.deliveryUnit['set_id'] ?? q.deliveryUnit['set_key'] ?? ''}'.trim();
  if (deliverySetId.isNotEmpty) {
    return '$docId|set_id:$deliverySetId';
  }
  final rf =
      '${q.setModel['range_from'] ?? q.setModel['rangeFrom'] ?? ''}'.trim();
  final rt = '${q.setModel['range_to'] ?? q.setModel['rangeTo'] ?? ''}'.trim();
  if (rf.isNotEmpty && rt.isNotEmpty) {
    return '$docId|range:$rf-$rt|$normStem';
  }
  final hdr =
      '${q.setModel['header_number'] ?? q.setModel['headerNumber'] ?? ''}'
          .trim();
  if (hdr.isNotEmpty) {
    return '$docId|hdr:$hdr|$normStem';
  }
  final modelKey =
      '${q.setModel['set_key'] ?? q.setModel['setKey'] ?? ''}'.trim();
  if (modelKey.isNotEmpty && !modelKey.startsWith('review_set:')) {
    return '$docId|key:$modelKey';
  }
  return '$docId|stem:$normStem';
}

List<ProblemBankGridSlot<T>> groupProblemBankGridSlots<T>(
  List<T> source,
  LearningProblemQuestion? Function(T item) questionOf,
) {
  final out = <ProblemBankGridSlot<T>>[];
  final setSlotIndexByKey = <String, int>{};

  for (var i = 0; i < source.length; i++) {
    final item = source[i];
    final q = questionOf(item);
    if (q == null) continue;
    final commonStem = q.setCommonStem.trim();
    final isIndSet = q.isIndependentSetItem && commonStem.isNotEmpty;
    if (!isIndSet) {
      out.add(
        ProblemBankGridSlot<T>(
          key: 'single:${q.stableQuestionKey}:$i',
          items: <T>[item],
          questions: <LearningProblemQuestion>[q],
          isIndependentSet: false,
        ),
      );
      continue;
    }

    final setKey = 'ind_set:${_independentSetIdentityOf(q)}';
    final existingIdx = setSlotIndexByKey[setKey];
    if (existingIdx != null) {
      final prev = out[existingIdx];
      final nextItems = <T>[...prev.items, item];
      final nextQuestions = <LearningProblemQuestion>[...prev.questions, q];
      out[existingIdx] = ProblemBankGridSlot<T>(
        key: prev.key,
        items: nextItems,
        questions: nextQuestions,
        isIndependentSet: true,
        commonStem: prev.commonStem,
        rangeLabel: formatIndependentSetRangeLabel(nextQuestions),
      );
    } else {
      final nextQuestions = <LearningProblemQuestion>[q];
      setSlotIndexByKey[setKey] = out.length;
      out.add(
        ProblemBankGridSlot<T>(
          key: setKey,
          items: <T>[item],
          questions: nextQuestions,
          isIndependentSet: true,
          commonStem: commonStem,
          rangeLabel: formatIndependentSetRangeLabel(nextQuestions),
        ),
      );
    }
  }
  return out;
}

/// 공통발문 카드의 `공통` 배지를 눌렀을 때 아래에 펼쳐지는 가로 하위 문항 리스트 영역.
class ProblemBankSetChildrenTray extends StatelessWidget {
  const ProblemBankSetChildrenTray({
    super.key,
    required this.children,
    required this.spacing,
  });

  static const double verticalPadding = 12.0;
  static const double horizontalPadding = 12.0;

  final List<Widget> children;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final panelStyle = FabTabBarTokens.previewAcademyPanelStyleFor(brightness);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical: verticalPadding,
      ),
      decoration: BoxDecoration(
        color: panelStyle.dropdownBackground,
        borderRadius: BorderRadius.circular(18),
        border: FabTabBarTokens.groupedCardBorderFor(brightness),
      ),
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          dragDevices: const {
            PointerDeviceKind.touch,
            PointerDeviceKind.mouse,
            PointerDeviceKind.trackpad,
            PointerDeviceKind.stylus,
          },
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) SizedBox(width: spacing),
                children[i],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class ProblemBankQuestionCard extends StatelessWidget {
  const ProblemBankQuestionCard({
    super.key,
    required this.question,
    required this.selected,
    required this.onSelectedChanged,
    required this.selectedMode,
    this.onModeSelected,
    this.figureUrlsByPath = const <String, String>{},
    this.showSelectionControl = true,
    this.paperStyle = false,
    this.previewImageUrl,
    this.previewPdfUrl,
    this.previewStatus = '',
    this.previewErrorMessage = '',
    this.onRetryPreview,
    this.showDragHandle = false,
    this.isCommonStemCard = false,
    this.titleOverride,
    this.selectedTristate,
    this.commonStemText,
    this.childQuestionCount = 0,
    this.commonSetExpanded = false,
    this.onToggleCommonSetExpanded,
    this.previewExpanded = false,
    this.onTogglePreviewExpand,
    this.measureKey,
    this.reviewThinkingScore,
    this.reviewArithmeticScore,
  });

  final LearningProblemQuestion question;
  final bool selected;
  final ValueChanged<bool> onSelectedChanged;
  final String selectedMode;
  final ValueChanged<String>? onModeSelected;
  final Map<String, String> figureUrlsByPath;
  final bool showSelectionControl;
  final bool paperStyle;
  final String? previewImageUrl;

  /// 구워 둔 문항 PDF. 있으면 V2 썸네일 이미지 대신 이 페이지를 보여 준다.
  final String? previewPdfUrl;
  final String previewStatus;
  final String previewErrorMessage;
  final VoidCallback? onRetryPreview;
  final bool showDragHandle;

  /// 독립형 세트문항의 공통발문 대표 카드 여부.
  final bool isCommonStemCard;
  final String? titleOverride;
  final bool? selectedTristate;
  final String? commonStemText;
  final int childQuestionCount;
  final bool commonSetExpanded;
  final VoidCallback? onToggleCommonSetExpanded;

  /// 썸네일이 고정 높이를 넘칠 때 하단 화살표로 펼친 상태.
  final bool previewExpanded;
  final VoidCallback? onTogglePreviewExpand;
  final String? measureKey;

  /// 세트 카드에 넘기는 하위 문항 점수 합. 개별 카드는 문항 자신의 점수를 쓴다.
  final double? reviewThinkingScore;
  final double? reviewArithmeticScore;

  String get _effectiveMeasureKey {
    final custom = measureKey?.trim() ?? '';
    if (custom.isNotEmpty) return custom;
    return isCommonStemCard
        ? 'common:${question.stableQuestionKey}'
        : question.stableQuestionKey;
  }

  String? get _effectivePreviewImageUrl {
    final pdf = previewPdfUrl?.trim() ?? '';
    if (pdf.isNotEmpty) return pdf;
    final image = previewImageUrl?.trim() ?? '';
    return image.isEmpty ? null : image;
  }

  double? get _effectiveThinkingScore => isCommonStemCard
      ? reviewThinkingScore
      : question.reviewThinkingScore;

  double? get _effectiveArithmeticScore => isCommonStemCard
      ? reviewArithmeticScore
      : question.reviewArithmeticScore;

  bool get _showsReviewScores =>
      _effectiveThinkingScore != null && _effectiveArithmeticScore != null;

  @override
  Widget build(BuildContext context) {
    final color = _palette(context, paperStyle: paperStyle);
    return LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth =
            constraints.maxWidth.isFinite && constraints.maxWidth > 0
                ? constraints.maxWidth
                : 428.0;
        return ListenableBuilder(
          listenable: ProblemBankPreviewSizeCache.instance,
          builder: (context, _) {
            final overflowing = ProblemBankPreviewSizeCache.instance
                .isOverflowing(
              measureKey: _effectiveMeasureKey,
              previewImageUrl: _effectivePreviewImageUrl,
              cardWidth: cardWidth,
            );
            final extraHeight = ProblemBankPreviewSizeCache.instance
                .extraHeightWhenExpanded(
              measureKey: _effectiveMeasureKey,
              previewImageUrl: _effectivePreviewImageUrl,
              cardWidth: cardWidth,
              expanded: previewExpanded,
            );
            return AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              decoration: BoxDecoration(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(14),
                // 선택 시에도 테두리 두께를 동일하게 유지해 안쪽 레이아웃이 밀리지 않게 함
                border: Border.all(color: Colors.transparent, width: 2),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildHeader(context, color),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      _kPreviewHorizontalInset,
                      _kHeaderPreviewGapHalf,
                      _kPreviewHorizontalInset,
                      _kContentBottomPadding,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          height: _kPreviewHeight + extraHeight,
                          child: _buildPreviewContent(
                            overflowing: overflowing,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(
                            left: _kMetaLeftInset - _kPreviewHorizontalInset,
                            top: _kMetaTopGap,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _metaSummaryText(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: color.textMuted,
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                    height: _kMetaLineHeight,
                                  ),
                                ),
                              ),
                              if (_showsReviewScores) ...[
                                const SizedBox(width: 8),
                                _buildReviewScoreRow(),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildPreviewContent({required bool overflowing}) {
    final borderColor =
        selected ? const Color(0xFF33A373) : Colors.grey.shade200;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_kPreviewBorderRadius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: selected ? 0.18 : 0.10),
            blurRadius: selected ? 16 : 12,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(_kPreviewBorderRadius),
            child: ColoredBox(
              color: Colors.white,
              child: _buildPreviewInner(),
            ),
          ),
          if (overflowing && onTogglePreviewExpand != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(_kPreviewBorderRadius),
                ),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: onTogglePreviewExpand,
                    child: Container(
                      height: _kPreviewExpandBarHeight,
                      alignment: Alignment.bottomCenter,
                      padding: const EdgeInsets.only(bottom: 3),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.white.withValues(
                              alpha: previewExpanded ? 0.85 : 0.0,
                            ),
                            Colors.white.withValues(alpha: 0.96),
                            Colors.white,
                          ],
                          stops: const [0.0, 0.45, 1.0],
                        ),
                      ),
                      child: Icon(
                        previewExpanded
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        size: 20,
                        color: const Color(0xFF4A5555),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOut,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(_kPreviewBorderRadius),
                  border: Border.all(
                    color: borderColor,
                    width: _kPreviewBorderWidth,
                    strokeAlign: BorderSide.strokeAlignInside,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewInner() {
    final pdfUrl = previewPdfUrl?.trim() ?? '';
    if (pdfUrl.isNotEmpty) {
      return SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        primary: false,
        child: _PreviewHeightMeasure(
          measureKey: _effectiveMeasureKey,
          child: IgnorePointer(
            child: ProblemBankBakedPdfPreview(url: pdfUrl),
          ),
        ),
      );
    }
    final normalizedStatus = previewStatus.trim().toLowerCase();
    final effectiveUrl = previewImageUrl?.trim() ?? '';
    if (effectiveUrl.isNotEmpty) {
      ProblemBankPreviewSizeCache.instance.resolveImage(effectiveUrl);
      return SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        primary: false,
        child: _PreviewHeightMeasure(
          measureKey: _effectiveMeasureKey,
          child: Image.network(
            effectiveUrl,
            width: double.infinity,
            fit: BoxFit.fitWidth,
            alignment: Alignment.topCenter,
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return const SizedBox(
                height: _kPreviewHeight,
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              );
            },
            errorBuilder: (context, error, stack) {
              return SizedBox(
                height: _kPreviewHeight,
                child: _buildServerState(
                  message: '서버 PDF 썸네일을 불러오지 못했습니다.',
                  showSpinner: false,
                  isError: true,
                ),
              );
            },
          ),
        ),
      );
    }
    if (normalizedStatus == 'queued' || normalizedStatus == 'running') {
      return _buildServerState(
        message: '서버 PDF 미리보기 생성 중...',
        showSpinner: true,
      );
    }
    if (normalizedStatus == 'failed' || normalizedStatus == 'cancelled') {
      return _buildServerState(
        message: previewErrorMessage.trim().isNotEmpty
            ? previewErrorMessage.trim()
            : '서버 PDF 미리보기에 실패했습니다.',
        showSpinner: false,
        isError: true,
      );
    }
    if (normalizedStatus == 'completed') {
      return _buildServerState(
        message: '미리보기 생성 완료 (썸네일 없음)',
        showSpinner: false,
      );
    }
    return _buildServerState(
      message: '서버 PDF 미리보기 대기 중...',
      showSpinner: true,
    );
  }

  Widget _buildServerState({
    required String message,
    required bool showSpinner,
    bool isError = false,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showSpinner) ...[
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(height: 8),
            ],
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color:
                    isError ? const Color(0xFF8B2F2F) : const Color(0xFF5A5A5A),
                fontWeight: FontWeight.w600,
              ),
            ),
            if (isError && onRetryPreview != null) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: onRetryPreview,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('다시 시도'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, _CardPalette color) {
    final availableModes = selectableQuestionModesOf(question);
    final effectiveSelected = normalizeQuestionModeSelection(
      question,
      selectedMode,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        6,
        _kHeaderTopPadding,
        6,
        _kHeaderPreviewGapHalf,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (showSelectionControl)
            SizedBox(
              width: 34,
              height: 28,
              child: Center(
                child: isCommonStemCard
                    ? Checkbox(
                        tristate: true,
                        value: selectedTristate,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        side: BorderSide(color: color.checkBorder),
                        activeColor: color.accent,
                        onChanged: (_) =>
                            onSelectedChanged(selectedTristate != true),
                      )
                    : Checkbox(
                        value: selected,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        side: BorderSide(color: color.checkBorder),
                        activeColor: color.accent,
                        onChanged: (v) => onSelectedChanged(v ?? false),
                      ),
              ),
            ),
          Expanded(
            child: _buildQuestionTitle(color),
          ),
          const SizedBox(width: 4),
          Flexible(
            flex: 0,
            child: isCommonStemCard
                ? _buildCommonBadgeButton(context, color)
                : _buildModeChipBar(
                    context,
                    availableModes: availableModes,
                    effectiveSelected: effectiveSelected,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildCommonBadgeButton(BuildContext context, _CardPalette color) {
    final brightness = Theme.of(context).brightness;
    final panelStyle = FabTabBarTokens.previewAcademyPanelStyleFor(brightness);
    final highlight = FabTabBarTokens.fabHighlightPillFill(brightness);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onToggleCommonSetExpanded,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          height: 28,
          padding: const EdgeInsets.fromLTRB(10, 0, 6, 0),
          decoration: BoxDecoration(
            color: commonSetExpanded ? highlight : panelStyle.dropdownBackground,
            borderRadius: BorderRadius.circular(999),
            border: commonSetExpanded
                ? Border.all(color: color.accent, width: 1)
                : FabTabBarTokens.groupedCardBorderFor(brightness),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '공통',
                style: TextStyle(
                  color: commonSetExpanded ? panelStyle.title : panelStyle.hint,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  height: 1,
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                commonSetExpanded
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
                size: 16,
                color: commonSetExpanded ? panelStyle.title : panelStyle.hint,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildModeChipBar(
    BuildContext context, {
    required List<String> availableModes,
    required String effectiveSelected,
  }) {
    final brightness = Theme.of(context).brightness;
    final panelStyle = FabTabBarTokens.previewAcademyPanelStyleFor(brightness);
    final enabled = onModeSelected != null && !paperStyle;

    return Container(
      height: 28,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: panelStyle.dropdownBackground,
        borderRadius: BorderRadius.circular(999),
        border: FabTabBarTokens.groupedCardBorderFor(brightness),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerRight,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < availableModes.length; i++) ...[
              if (i > 0) const SizedBox(width: 2),
              _buildModeChip(
                context,
                availableModes[i],
                isSelected: availableModes[i] == effectiveSelected,
                enabled: enabled,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildQuestionTitle(_CardPalette color) {
    final titleText = (titleOverride?.trim().isNotEmpty ?? false)
        ? titleOverride!.trim()
        : question.displayQuestionNumber;
    final titleStyle = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w800,
      color: color.textPrimary,
    );
    if (isCommonStemCard) {
      return Text(
        titleText,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: titleStyle,
      );
    }
    final difficultyLabel = _difficultyLabel();
    if (difficultyLabel.isEmpty) {
      return Text(
        titleText,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: titleStyle,
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            titleText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: titleStyle,
          ),
        ),
        const SizedBox(width: 3),
        _DifficultyDot(
          label: difficultyLabel,
          paperStyle: paperStyle,
        ),
      ],
    );
  }

  String _difficultyLabel() {
    String readString(Object? value) => value == null ? '' : '$value'.trim();
    String normalizeLabel(String raw) {
      final compact = raw.trim().replaceAll(RegExp(r'\s+'), '');
      if (compact == '대표문제') return '대표 문제';
      return raw.trim();
    }

    Map<String, dynamic> mapOf(Object? value) {
      if (value is Map<String, dynamic>) return value;
      if (value is Map) {
        return value.map((key, val) => MapEntry('$key', val));
      }
      return const <String, dynamic>{};
    }

    final meta = question.meta;
    final direct = readString(
      meta['textbook_difficulty_label'] ??
          meta['difficulty_label'] ??
          meta['difficultyLabel'],
    );
    if (direct.isNotEmpty) return normalizeLabel(direct);

    final crop = mapOf(meta['textbook_crop'] ?? meta['textbookCrop']);
    final cropLabel = readString(
      crop['difficulty_label'] ?? crop['difficultyLabel'] ?? crop['label'],
    );
    if (cropLabel.isNotEmpty) return normalizeLabel(cropLabel);

    final cropPage =
        mapOf(meta['textbook_crop_page'] ?? meta['textbookCropPage']);
    final cropPageLabel = readString(
      cropPage['difficulty_label'] ??
          cropPage['difficultyLabel'] ??
          cropPage['label'],
    );
    return normalizeLabel(cropPageLabel);
  }

  String _metaSummaryText() {
    if (isCommonStemCard) {
      final range = (titleOverride?.trim().isNotEmpty ?? false)
          ? '${titleOverride!.trim()}번'
          : '';
      final parts = <String>[
        if (question.schoolName.isNotEmpty) question.schoolName.trim(),
        if (question.examYear != null) '${question.examYear}',
        if (question.gradeLabel.isNotEmpty) question.gradeLabel.trim(),
        if (question.semesterLabel.isNotEmpty) question.semesterLabel.trim(),
        if (question.examTermLabel.isNotEmpty) question.examTermLabel.trim(),
        if (range.isNotEmpty) range,
        if (childQuestionCount > 0) '공통 $childQuestionCount문항',
      ];
      if (parts.isEmpty) return '공통발문';
      return parts.join(', ');
    }
    final originalNumber = question.questionNumber.trim().isNotEmpty
        ? question.questionNumber.trim()
        : question.displayQuestionNumber;
    final parts = <String>[
      if (question.schoolName.isNotEmpty) question.schoolName.trim(),
      if (question.examYear != null) '${question.examYear}',
      if (question.gradeLabel.isNotEmpty) question.gradeLabel.trim(),
      if (question.semesterLabel.isNotEmpty) question.semesterLabel.trim(),
      if (question.examTermLabel.isNotEmpty) question.examTermLabel.trim(),
      if (originalNumber.isNotEmpty) '$originalNumber번',
    ];
    if (parts.isEmpty) return '-';
    return parts.join(', ');
  }

  Widget _buildReviewScoreRow() {
    final thinking = _effectiveThinkingScore;
    final arithmetic = _effectiveArithmeticScore;
    if (thinking == null || arithmetic == null) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ReviewScoreChip(label: '사고', score: thinking),
        const SizedBox(width: 6),
        _ReviewScoreChip(label: '연산', score: arithmetic),
      ],
    );
  }

  Widget _buildModeChip(
    BuildContext context,
    String mode, {
    required bool isSelected,
    required bool enabled,
  }) {
    final brightness = Theme.of(context).brightness;
    final panelStyle = FabTabBarTokens.previewAcademyPanelStyleFor(brightness);
    final highlight = FabTabBarTokens.fabHighlightPillFill(brightness);
    final label = _modeChipLabel(mode);
    final tooltip = questionModeLabelOf(mode);

    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 450),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: isSelected ? highlight : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: enabled ? () => onModeSelected?.call(mode) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
              child: Text(
                label,
                style: TextStyle(
                  color: isSelected ? panelStyle.title : panelStyle.hint,
                  fontSize: 10.5,
                  fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                  letterSpacing: 0.1,
                  height: 1,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _modeChipLabel(String mode) {
    switch (mode.trim()) {
      case kLearningQuestionModeObjective:
        return '객';
      case kLearningQuestionModeSubjective:
        return '주';
      case kLearningQuestionModeEssay:
        return '서';
      case kLearningQuestionModeOriginal:
      default:
        return '기본';
    }
  }
}

class _ReviewScoreChip extends StatelessWidget {
  const _ReviewScoreChip({
    required this.label,
    required this.score,
  });

  final String label;
  final double score;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final panelStyle = FabTabBarTokens.previewAcademyPanelStyleFor(brightness);
    return Container(
      height: _kReviewScoreChipHeight,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: panelStyle.dropdownBackground,
        borderRadius: BorderRadius.circular(999),
        border: FabTabBarTokens.groupedCardBorderFor(brightness),
      ),
      child: Text(
        '$label ${_formatReviewScore(score)}',
        maxLines: 1,
        style: TextStyle(
          color: panelStyle.title,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
    );
  }
}

String _formatReviewScore(double value) {
  final rounded = (value * 100).round() / 100.0;
  var text = rounded.toStringAsFixed(2);
  text = text.replaceFirst(RegExp(r'0+$'), '');
  text = text.replaceFirst(RegExp(r'\.$'), '');
  return text;
}

class _PreviewHeightMeasure extends SingleChildRenderObjectWidget {
  const _PreviewHeightMeasure({
    required this.measureKey,
    required super.child,
  });

  final String measureKey;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderPreviewHeightMeasure(measureKey);
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderPreviewHeightMeasure renderObject,
  ) {
    renderObject.measureKey = measureKey;
  }
}

class _RenderPreviewHeightMeasure extends RenderProxyBox {
  _RenderPreviewHeightMeasure(this.measureKey);

  String measureKey;

  @override
  void performLayout() {
    super.performLayout();
    if (size.width > 0 && size.height > 0) {
      ProblemBankPreviewSizeCache.instance.recordMeasuredSize(measureKey, size);
    }
  }
}

class _DifficultyDot extends StatelessWidget {
  const _DifficultyDot({
    required this.label,
    required this.paperStyle,
  });

  final String label;
  final bool paperStyle;

  @override
  Widget build(BuildContext context) {
    final colors = _difficultyColors(label, paperStyle: paperStyle);
    final display = _displayLabel(label);
    return Tooltip(
      message: '난이도 $label',
      waitDuration: const Duration(milliseconds: 450),
      child: Container(
        width: 18,
        height: 18,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: colors.$1,
          border: Border.all(color: colors.$2),
        ),
        child: Text(
          display,
          maxLines: 1,
          overflow: TextOverflow.clip,
          style: TextStyle(
            color: colors.$3,
            fontSize: display.length >= 2 ? 8.5 : 10,
            fontWeight: FontWeight.w800,
            height: 1,
          ),
        ),
      ),
    );
  }

  static String _displayLabel(String label) {
    final safe = label.trim();
    if (safe.isEmpty) return '';
    if (safe.length <= 2) return safe;
    final upper = safe.toUpperCase();
    final abc = RegExp(r'[ABC]').firstMatch(upper);
    if (abc != null) return abc.group(0) ?? safe.substring(0, 1);
    return safe.substring(0, 1);
  }

  static (Color, Color, Color) _difficultyColors(
    String label, {
    required bool paperStyle,
  }) {
    final safe = label.trim().toLowerCase();
    final isEasy = safe.contains('하') ||
        safe.contains('쉬') ||
        safe.contains('easy') ||
        safe == 'a';
    final isHard = safe.contains('상') ||
        safe.contains('고난') ||
        safe.contains('심화') ||
        safe == 'c';
    if (isEasy) {
      return paperStyle
          ? (
              const Color(0xFFE7F1EA),
              const Color(0xFFB9D5C1),
              const Color(0xFF366947)
            )
          : (
              const Color(0xFF21362D),
              const Color(0xFF547B62),
              const Color(0xFFC3DEC8)
            );
    }
    if (isHard) {
      return paperStyle
          ? (
              const Color(0xFFF2E8E5),
              const Color(0xFFD9BDB4),
              const Color(0xFF7A4B3D)
            )
          : (
              const Color(0xFF3A2C2A),
              const Color(0xFF7C5C55),
              const Color(0xFFE1C6BE)
            );
    }
    return paperStyle
        ? (
            const Color(0xFFE7EDF2),
            const Color(0xFFB9C8D5),
            const Color(0xFF3D5D73)
          )
        : (
            const Color(0xFF24323A),
            const Color(0xFF516B7A),
            const Color(0xFFC4D5DE)
          );
  }
}

class _CardPalette {
  const _CardPalette({
    required this.textPrimary,
    required this.textMuted,
    required this.checkBorder,
    required this.accent,
  });

  final Color textPrimary;
  final Color textMuted;
  final Color checkBorder;
  final Color accent;
}

_CardPalette _palette(
  BuildContext context, {
  required bool paperStyle,
}) {
  if (paperStyle) {
    return const _CardPalette(
      textPrimary: Color(0xFF232323),
      textMuted: Color(0xFF66727A),
      checkBorder: Color(0xFF9E9E9E),
      accent: Color(0xFF1B6B63),
    );
  }
  final brightness = Theme.of(context).brightness;
  final panelStyle = FabTabBarTokens.previewAcademyPanelStyleFor(brightness);
  return _CardPalette(
    textPrimary: panelStyle.title,
    textMuted: panelStyle.hint,
    checkBorder: panelStyle.border,
    accent: const Color(0xFF33A373),
  );
}

class _SharedBakedPdfDocuments {
  static final Map<String, Future<PdfDocument>> _opening =
      <String, Future<PdfDocument>>{};

  static Future<PdfDocument> open(String url) {
    return _opening.putIfAbsent(url, () async {
      try {
        return await PdfDocument.openUri(Uri.parse(url));
      } catch (_) {
        _opening.remove(url);
        rethrow;
      }
    });
  }
}

/// 구워 둔 문항 PDF의 첫 페이지. 카드 너비에 맞춰 높이가 정해진다.
class ProblemBankBakedPdfPreview extends StatefulWidget {
  const ProblemBankBakedPdfPreview({super.key, required this.url});

  final String url;

  @override
  State<ProblemBankBakedPdfPreview> createState() =>
      _ProblemBankBakedPdfPreviewState();
}

class _ProblemBankBakedPdfPreviewState extends State<ProblemBankBakedPdfPreview> {
  PdfDocument? _document;
  Object? _error;
  double? _aspect;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant ProblemBankBakedPdfPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) unawaited(_load());
  }

  Future<void> _load() async {
    final url = widget.url.trim();
    if (url.isEmpty) return;
    setState(() {
      _error = null;
      _document = null;
      _aspect = null;
    });
    try {
      final document = await _SharedBakedPdfDocuments.open(url);
      if (!mounted || widget.url.trim() != url) return;
      final page = document.pages.isEmpty ? null : document.pages.first;
      final aspect = page == null || page.width <= 0 || page.height <= 0
          ? null
          : page.width / page.height;
      if (aspect != null) {
        ProblemBankPreviewSizeCache.instance.recordAspectRatio(url, aspect);
      }
      setState(() {
        _document = document;
        _aspect = aspect;
        _error = page == null ? 'empty' : null;
      });
    } catch (error) {
      if (!mounted || widget.url.trim() != url) return;
      setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return const SizedBox(
        height: _kPreviewHeight,
        child: Center(
          child: Text(
            '문항 PDF를 표시할 수 없습니다.',
            style: TextStyle(
              color: Color(0xFF6E7E96),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }
    final document = _document;
    final aspect = _aspect;
    if (document == null || aspect == null || aspect <= 0) {
      return const SizedBox(
        height: _kPreviewHeight,
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite && constraints.maxWidth > 0
            ? constraints.maxWidth
            : 320.0;
        final height = width / aspect;
        return ColoredBox(
          color: Colors.white,
          child: SizedBox(
            width: width,
            height: height,
            child: PdfPageView(
              document: document,
              pageNumber: 1,
              decoration: const BoxDecoration(color: Colors.white),
            ),
          ),
        );
      },
    );
  }
}
