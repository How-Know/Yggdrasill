import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../screens/design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';
import 'latex_text_renderer.dart';

const double resourceTextbookCardCoverA4Ratio = 1.414;
const double resourceTextbookCardMetaHeight = 77.0;
const double resourceTextbookCardCoverMetaGap = 14.0;
const double resourceTextbookCardDefaultWidth = 240.0;

List<BoxShadow> resourceTextbookCoverBoxShadows() => [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.10),
        blurRadius: 14,
      ),
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.16),
        blurRadius: 18,
        spreadRadius: -2,
        offset: const Offset(3, 7),
      ),
    ];

ImageProvider? resourceTextbookCoverImageProvider(String rawPath) {
  final path = rawPath.trim();
  if (path.isEmpty) return null;
  if (path.startsWith('http://') || path.startsWith('https://')) {
    return NetworkImage(path);
  }
  var localPath = path;
  if (path.startsWith('file://')) {
    final uri = Uri.tryParse(path);
    if (uri != null) localPath = uri.toFilePath();
  }
  final file = File(localPath);
  if (!file.existsSync()) return null;
  return FileImage(file);
}

/// 자료 탭 교재 카드와 동일한 비주얼 — 선택 전용(문제은행 사설 교재 피커 등).
class ResourceTextbookCard extends StatelessWidget {
  const ResourceTextbookCard({
    super.key,
    required this.title,
    this.description,
    this.gradeLabel,
    this.coverPath,
    this.backgroundColor,
    this.selected = false,
    this.onTap,
    this.width = resourceTextbookCardDefaultWidth,
  });

  final String title;
  final String? description;
  final String? gradeLabel;
  final String? coverPath;
  final Color? backgroundColor;
  final bool selected;
  final VoidCallback? onTap;
  final double width;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final panelStyle = FabTabBarTokens.previewAcademyPanelStyleFor(brightness);
    final cardRadius = FabTabBarTokens.previewAcademyGroupedCardRadius;
    final coverImage = resourceTextbookCoverImageProvider(coverPath ?? '');
    final hasCoverImage = coverImage != null;
    final bg = backgroundColor ?? const Color(0xFF2B2B2B);
    final cardHeight = width * resourceTextbookCardCoverA4Ratio +
        resourceTextbookCardMetaHeight;

    return SizedBox(
      width: width,
      height: cardHeight,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(cardRadius),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(cardRadius),
              border: Border.all(
                color: selected
                    ? FabTabBarTokens.fabHighlightPillFill(brightness)
                        .withValues(alpha: 0.95)
                    : Colors.transparent,
                width: selected ? 2 : 0,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, box) {
                      final desiredCoverHeight =
                          box.maxWidth * resourceTextbookCardCoverA4Ratio;
                      final coverHeight = math.min(
                        desiredCoverHeight,
                        math.max(
                          0.0,
                          box.maxHeight - resourceTextbookCardMetaHeight,
                        ),
                      );
                      final metaHeight = math.max(
                        0.0,
                        box.maxHeight -
                            coverHeight -
                            resourceTextbookCardCoverMetaGap,
                      );

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            height: coverHeight,
                            width: double.infinity,
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                Positioned.fill(
                                  child: IgnorePointer(
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        borderRadius:
                                            BorderRadius.circular(cardRadius),
                                        boxShadow:
                                            resourceTextbookCoverBoxShadows(),
                                      ),
                                    ),
                                  ),
                                ),
                                Positioned.fill(
                                  child: ClipRRect(
                                    borderRadius:
                                        BorderRadius.circular(cardRadius),
                                    child: ColoredBox(
                                      color: hasCoverImage
                                          ? bg
                                          : const Color(0xFF2B2B2B),
                                      child: hasCoverImage
                                          ? Image(
                                              image: coverImage,
                                              fit: BoxFit.cover,
                                            )
                                          : Center(
                                              child: Icon(
                                                Icons.menu_book,
                                                size: 36,
                                                color: Colors.white
                                                    .withValues(alpha: 0.6),
                                              ),
                                            ),
                                    ),
                                  ),
                                ),
                                if (selected)
                                  Positioned.fill(
                                    child: IgnorePointer(
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          borderRadius:
                                              BorderRadius.circular(cardRadius),
                                          color: FabTabBarTokens
                                                  .fabHighlightPillFill(
                                                      brightness)
                                              .withValues(alpha: 0.18),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(
                              height: resourceTextbookCardCoverMetaGap),
                          SizedBox(
                            height: metaHeight,
                            width: double.infinity,
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: LatexTextRenderer(
                                          title,
                                          maxLines: 1,
                                          softWrap: false,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: panelStyle.title,
                                            fontSize: 18,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: -0.2,
                                          ),
                                        ),
                                      ),
                                      if (gradeLabel != null &&
                                          gradeLabel!.trim().isNotEmpty) ...[
                                        const SizedBox(width: 6),
                                        _MiniGradePill(
                                            text: gradeLabel!.trim()),
                                      ],
                                    ],
                                  ),
                                  if ((description ?? '')
                                      .trim()
                                      .isNotEmpty) ...[
                                    const SizedBox(height: 1),
                                    LatexTextRenderer(
                                      description!.trim(),
                                      maxLines: 1,
                                      softWrap: false,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: panelStyle.hint,
                                        fontSize: 14.5,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniGradePill extends StatelessWidget {
  const _MiniGradePill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final panelStyle = FabTabBarTokens.previewAcademyPanelStyleFor(
      Theme.of(context).brightness,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: panelStyle.dropdownBackground,
        borderRadius: BorderRadius.circular(999),
        border: FabTabBarTokens.groupedCardBorderFor(
          Theme.of(context).brightness,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Text(
          text,
          style: TextStyle(
            color: panelStyle.label,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
