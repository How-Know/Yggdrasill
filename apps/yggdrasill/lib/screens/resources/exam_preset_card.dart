import 'package:flutter/material.dart';

import '../design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';
import '../../widgets/dialog_tokens.dart';
import '../../services/learning_problem_bank_service.dart';
import 'exam_preset_support.dart';

List<BoxShadow> examPresetCardBoxShadows() => [
      BoxShadow(
        color: Colors.black.withOpacity(0.10),
        blurRadius: 14,
        spreadRadius: 0,
      ),
      BoxShadow(
        color: Colors.black.withOpacity(0.16),
        blurRadius: 18,
        spreadRadius: -2,
        offset: const Offset(3, 7),
      ),
    ];

class ExamPresetCard extends StatelessWidget {
  const ExamPresetCard({
    super.key,
    required this.preset,
    required this.onTap,
    this.busy = false,
  });

  final LearningProblemDocumentExportPreset preset;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final parsed = parsedNaesinLinkOfPreset(preset);
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    final cardRadius = FabTabBarTokens.previewAcademyGroupedCardRadius;
    final line1 = parsed == null ? preset.displayName : examPresetCardLine1(parsed);
    final line2 = parsed == null ? '' : examPresetCardLine2(parsed);
    final textColor = isDark ? Colors.white : const Color(0xFF1A1A1A);
    final subColor = isDark ? Colors.white70 : const Color(0xFF666666);

    return MouseRegion(
      cursor: onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: busy ? null : onTap,
        child: Opacity(
          opacity: busy ? 0.65 : 1,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(cardRadius),
                      boxShadow: examPresetCardBoxShadows(),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(cardRadius),
                  child: Material(
                    color: isDark
                        ? const Color(0xFF2B2B2B)
                        : const Color(0xFFF4F4F4),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 16, 14, 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            line1,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: textColor,
                              fontSize: FabTabBarTokens.fabBarLabelFontSize,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.2,
                              height: 1.25,
                            ),
                          ),
                          if (line2.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(
                              line2,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: subColor,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                letterSpacing: -0.1,
                                height: 1.2,
                              ),
                            ),
                          ],
                          const Spacer(),
                          Row(
                            children: [
                              Icon(
                                Icons.picture_as_pdf_outlined,
                                size: 14,
                                color: isDark
                                    ? const Color(0xFF7FB8A8)
                                    : const Color(0xFF33A373),
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  '탭하여 서버 PDF 미리보기',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: isDark
                                        ? const Color(0xFF7FB8A8)
                                        : const Color(0xFF33A373),
                                    fontSize: 11.4,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (busy)
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(cardRadius),
                    child: const ColoredBox(
                      color: Color(0x33000000),
                      child: Center(
                        child: YggLoadingIndicator(size: 22),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
