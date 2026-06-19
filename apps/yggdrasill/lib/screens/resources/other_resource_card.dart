import 'package:flutter/material.dart';

import '../design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';
import '../../widgets/dialog_tokens.dart';
import 'exam_preset_card.dart';

/// 기타 탭 문서 카드 — [ExamPresetCard]와 동일한 글래스·2줄 레이아웃.
class OtherResourceCard extends StatelessWidget {
  const OtherResourceCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.onHwpTap,
    this.hasPdf = false,
    this.hasHwp = false,
    this.busy = false,
  });

  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final VoidCallback? onHwpTap;
  final bool hasPdf;
  final bool hasHwp;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    final cardRadius = FabTabBarTokens.previewAcademyGroupedCardRadius;
    final textColor = isDark ? Colors.white : const Color(0xFF1A1A1A);
    final subColor = isDark ? Colors.white70 : const Color(0xFF666666);
    final accentColor =
        isDark ? const Color(0xFF7FB8A8) : const Color(0xFF33A373);

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
                            title,
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
                          if (subtitle.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(
                              subtitle,
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
                                color: hasPdf ? accentColor : subColor,
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  hasPdf ? '탭하여 PDF 열기' : 'PDF 없음',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: hasPdf ? accentColor : subColor,
                                    fontSize: 11.4,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              if (hasHwp) ...[
                                const SizedBox(width: 6),
                                GestureDetector(
                                  onTap: busy ? null : onHwpTap,
                                  behavior: HitTestBehavior.opaque,
                                  child: MouseRegion(
                                    cursor: onHwpTap == null
                                        ? SystemMouseCursors.basic
                                        : SystemMouseCursors.click,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isDark
                                            ? const Color(0xFF3A3F44)
                                            : const Color(0xFFE4E4E4),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        'HWP',
                                        style: TextStyle(
                                          color: isDark
                                              ? Colors.white70
                                              : const Color(0xFF444444),
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
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
