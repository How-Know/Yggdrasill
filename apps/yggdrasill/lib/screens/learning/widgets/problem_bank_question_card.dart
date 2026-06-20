import 'package:flutter/material.dart';

import '../../../services/learning_problem_bank_service.dart';
import '../../design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';
import '../models/problem_bank_export_models.dart';

const double _kPreviewHorizontalInset = 8;
const double _kPreviewBorderRadius = 10;
const double _kPreviewBorderWidth = 1.4;
const double _kPreviewHeight = 222;
// 헤더↔썸네일 간격: 12 → 9.6 → 추가 20% 축소 ≈ 7.68
const double _kHeaderTopPadding = 6;
const double _kHeaderPreviewGapHalf = 3.84;
const double _kContentBottomPadding = 4;
// 썸네일↔메타 간격: 기존 4의 2배 (줄간격 2배는 이 여백으로 표현)
const double _kMetaTopGap = 8;
const double _kMetaLineHeight = 1.3;
const double _kMetaLeftInset = _kPreviewHorizontalInset + 2;

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
    this.previewStatus = '',
    this.previewErrorMessage = '',
    this.onRetryPreview,
    this.showDragHandle = false,
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
  final String previewStatus;
  final String previewErrorMessage;
  final VoidCallback? onRetryPreview;
  final bool showDragHandle;

  @override
  Widget build(BuildContext context) {
    final color = _palette(context, paperStyle: paperStyle);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        // 선택 시에도 테두리 두께를 동일하게 유지해 안쪽 레이아웃이 밀리지 않게 함
        border: Border.all(color: Colors.transparent, width: 2),
      ),
      child: Column(
        children: [
          _buildHeader(context, color),
          Padding(
            padding: EdgeInsets.fromLTRB(
              _kPreviewHorizontalInset,
              _kHeaderPreviewGapHalf,
              _kPreviewHorizontalInset,
              _kContentBottomPadding,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: _kPreviewHeight,
                  child: _buildPreviewContent(),
                ),
                Padding(
                  padding: EdgeInsets.only(
                    left: _kMetaLeftInset - _kPreviewHorizontalInset,
                    top: _kMetaTopGap,
                  ),
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
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewContent() {
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
    final normalizedStatus = previewStatus.trim().toLowerCase();
    if (previewImageUrl != null && previewImageUrl!.isNotEmpty) {
      return SizedBox.expand(
        child: Image.network(
          previewImageUrl!,
          fit: BoxFit.fitWidth,
          alignment: Alignment.topCenter,
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return const SizedBox(
              height: 200,
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
            return _buildServerState(
              message: '서버 PDF 썸네일을 불러오지 못했습니다.',
              showSpinner: false,
              isError: true,
            );
          },
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
      padding: EdgeInsets.fromLTRB(
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
                child: Checkbox(
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
            child: _buildModeChipBar(
              context,
              availableModes: availableModes,
              effectiveSelected: effectiveSelected,
            ),
          ),
        ],
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
    final difficultyLabel = _difficultyLabel();
    final titleStyle = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w800,
      color: color.textPrimary,
    );
    if (difficultyLabel.isEmpty) {
      return Text(
        question.displayQuestionNumber,
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
            question.displayQuestionNumber,
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
        safe.contains('hard') ||
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
