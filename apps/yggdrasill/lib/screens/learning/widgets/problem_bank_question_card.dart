import 'package:flutter/material.dart';

import '../../../services/learning_problem_bank_service.dart';
import '../models/problem_bank_export_models.dart';

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

  @override
  Widget build(BuildContext context) {
    final color = _palette(paperStyle: paperStyle, selected: selected);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      decoration: BoxDecoration(
        color: color.cardBg,
        borderRadius: BorderRadius.circular(14),
        // 선택 시에도 테두리 두께를 동일하게 유지해 안쪽 레이아웃이 밀리지 않게 함
        border: Border.all(color: color.border, width: 2),
        boxShadow: color.boxShadow,
      ),
      child: Column(
        children: [
          _buildHeader(color),
          Divider(height: 1, color: color.divider),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _buildPreviewContent(),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _metaSummaryText(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: color.textMuted,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewContent() {
    final wrapper = Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.grey.shade200),
      ),
      clipBehavior: Clip.antiAlias,
      child: _buildPreviewInner(),
    );
    return wrapper;
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

  Widget _buildHeader(_CardPalette color) {
    final availableModes = selectableQuestionModesOf(question);
    final originalMode = originalQuestionModeOf(question);
    final effectiveSelected = normalizeQuestionModeSelection(
      question,
      selectedMode,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showSelectionControl)
            Checkbox(
              value: selected,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              side: BorderSide(color: color.checkBorder),
              activeColor: color.accent,
              onChanged: (v) => onSelectedChanged(v ?? false),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: _buildQuestionTitle(color),
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Align(
              alignment: Alignment.topRight,
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                alignment: WrapAlignment.end,
                children: [
                  for (final mode in availableModes)
                    _buildModeChip(
                      mode,
                      color: color,
                      isOriginal: mode == originalMode,
                      isSelected: mode == effectiveSelected,
                    ),
                ],
              ),
            ),
          ),
        ],
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
        '${question.displayQuestionNumber}번 문항',
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
            '${question.displayQuestionNumber}번 문항',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: titleStyle,
          ),
        ),
        const SizedBox(width: 5),
        _DifficultyDot(
          label: difficultyLabel,
          paperStyle: paperStyle,
        ),
      ],
    );
  }

  String _difficultyLabel() {
    String readString(Object? value) => value == null ? '' : '$value'.trim();
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
    if (direct.isNotEmpty) return direct;

    final crop = mapOf(meta['textbook_crop'] ?? meta['textbookCrop']);
    final cropLabel = readString(
      crop['difficulty_label'] ?? crop['difficultyLabel'] ?? crop['label'],
    );
    if (cropLabel.isNotEmpty) return cropLabel;

    final cropPage =
        mapOf(meta['textbook_crop_page'] ?? meta['textbookCropPage']);
    final cropPageLabel = readString(
      cropPage['difficulty_label'] ??
          cropPage['difficultyLabel'] ??
          cropPage['label'],
    );
    return cropPageLabel;
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
    String mode, {
    required _CardPalette color,
    required bool isOriginal,
    required bool isSelected,
  }) {
    final label = questionModeLabelOf(mode);
    final enabled = onModeSelected != null && !paperStyle;
    final bg = isOriginal ? color.badgeBg : Colors.transparent;
    final borderColor = isSelected
        ? color.accent
        : (isOriginal ? color.badgeBorder : color.metaChipBorder);
    final textColor = isOriginal ? color.badgeText : color.textMuted;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: enabled ? () => onModeSelected?.call(mode) : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isSelected) ...[
                Icon(
                  Icons.check_rounded,
                  size: 12,
                  color: isOriginal ? color.badgeText : color.accent,
                ),
                const SizedBox(width: 2),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: textColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
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
        width: 20,
        height: 20,
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
    required this.cardBg,
    required this.border,
    required this.divider,
    required this.textPrimary,
    required this.textMuted,
    required this.badgeBg,
    required this.badgeBorder,
    required this.badgeText,
    required this.metaChipBg,
    required this.metaChipBorder,
    required this.checkBorder,
    required this.accent,
    required this.boxShadow,
  });

  final Color cardBg;
  final Color border;
  final Color divider;
  final Color textPrimary;
  final Color textMuted;
  final Color badgeBg;
  final Color badgeBorder;
  final Color badgeText;
  final Color metaChipBg;
  final Color metaChipBorder;
  final Color checkBorder;
  final Color accent;
  final List<BoxShadow> boxShadow;
}

_CardPalette _palette({
  required bool paperStyle,
  required bool selected,
}) {
  if (paperStyle) {
    return _CardPalette(
      cardBg: Colors.white,
      border: selected ? const Color(0xFF9EC5AF) : const Color(0xFFE0E0E0),
      divider: const Color(0xFFEDEDED),
      textPrimary: const Color(0xFF232323),
      textMuted: const Color(0xFF66727A),
      badgeBg: const Color(0xFFE8F1EC),
      badgeBorder: const Color(0xFFC8DDD0),
      badgeText: const Color(0xFF2F6D4E),
      metaChipBg: const Color(0xFFF6F6F6),
      metaChipBorder: const Color(0xFFE7E7E7),
      checkBorder: const Color(0xFF9E9E9E),
      accent: const Color(0xFF1B6B63),
      boxShadow: const [
        BoxShadow(
          color: Color(0x11000000),
          blurRadius: 8,
          offset: Offset(0, 3),
        ),
      ],
    );
  }
  return _CardPalette(
    cardBg: const Color(0xFF15171C),
    border: selected ? const Color(0xFF2F786B) : const Color(0xFF223131),
    divider: const Color(0xFF223131),
    textPrimary: const Color(0xFFEAF2F2),
    textMuted: const Color(0xFF9FB3B3),
    badgeBg: const Color(0xFF173C36),
    badgeBorder: const Color(0xFF2B6B61),
    badgeText: const Color(0xFFBEE7D2),
    metaChipBg: const Color(0xFF151E24),
    metaChipBorder: const Color(0xFF223131),
    checkBorder: const Color(0xFF5C7272),
    accent: const Color(0xFF1B6B63),
    boxShadow: const [],
  );
}
