import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../services/student_api.dart';
import 'student_bottom_nav_bar.dart';

/// 하단 검색창 위에 뜨는 개념 이름 목록.
class ConceptSearchPanel extends StatelessWidget {
  const ConceptSearchPanel({
    super.key,
    required this.hits,
    required this.loading,
    required this.onSelect,
  });

  final List<ConceptSearchHit> hits;
  final bool loading;
  final ValueChanged<ConceptSearchHit> onSelect;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = isDark
        ? StudentBottomNavTokens.darkSurface
        : StudentBottomNavTokens.lightSurface;
    final title = isDark
        ? StudentBottomNavTokens.darkSelected
        : StudentBottomNavTokens.lightSelected;
    final hint = isDark
        ? StudentBottomNavTokens.darkUnselected
        : StudentBottomNavTokens.lightUnselected;
    final blur = StudentBottomNavTokens.blurFor(Theme.of(context).brightness);
    const radius = BorderRadius.all(Radius.circular(22));

    final body = loading
        ? const SizedBox(
            height: 72,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          )
        : hits.isEmpty
            ? SizedBox(
                height: 72,
                child: Center(
                  child: Text(
                    '해당하는 개념이 없어요.',
                    style: TextStyle(
                      color: hint,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              )
            : ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 6),
                itemCount: hits.length,
                separatorBuilder: (_, __) => Divider(
                  height: 1,
                  color: title.withValues(alpha: 0.08),
                ),
                itemBuilder: (context, index) {
                  final hit = hits[index];
                  final name = hit.name.isEmpty ? '(이름 없음)' : hit.name;
                  final meta = [
                    if (hit.categoryLabel.isNotEmpty) hit.categoryLabel,
                    if (hit.courses.isNotEmpty) hit.courses,
                  ].join('  ·  ');
                  return InkWell(
                    onTap: () => onSelect(hit),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: title,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (meta.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              meta,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: hint,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              );

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: isDark ? null : StudentBottomNavTokens.lightShadows,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: CustomPaint(
            foregroundPainter: GlassRimPainter(isDark: isDark),
            child: DecoratedBox(
              decoration: BoxDecoration(color: surface, borderRadius: radius),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: body,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 개념 이름과 본문.
Future<void> showConceptSearchDetail(
  BuildContext context,
  ConceptSearchHit hit,
) {
  final name = hit.name.trim().isEmpty ? '(이름 없음)' : hit.name.trim();
  final body = hit.content.trim();
  return showDialog<void>(
    context: context,
    builder: (ctx) {
      final isDark = Theme.of(ctx).brightness == Brightness.dark;
      final surface =
          isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7);
      final card = isDark ? const Color(0xFF2C2C2E) : Colors.white;
      final text = isDark ? Colors.white : Colors.black;
      final sub = isDark
          ? Colors.white.withValues(alpha: 0.55)
          : Colors.black.withValues(alpha: 0.45);
      final category = hit.categoryLabel.trim();
      final course = hit.courses.trim();
      final leftMeta = [
        if (course.isNotEmpty) course,
        if (category.isNotEmpty) category,
      ].join(' · ');
      final media = MediaQuery.sizeOf(ctx);
      // 계정 시트와 같은 폭·껍질. 프로필 편집 다이얼로그와 같은 화면 여백.
      final dialogW = (media.width - 32).clamp(360.0, 560.0);
      final maxHeight = media.height * 0.72;
      const headerH = 56.0;
      const chrome = 4.0 * 2 + 12 + 20 + headerH + 12;
      return Material(
        type: MaterialType.transparency,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: dialogW,
                maxHeight: maxHeight,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: surface,
                  borderRadius: BorderRadius.circular(34),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 32,
                      offset: Offset(0, 12),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          height: headerH,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 148,
                                ),
                                child: Text(
                                  name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: text,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                    decoration: TextDecoration.none,
                                  ),
                                ),
                              ),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 140,
                                  ),
                                  child: Text(
                                    leftMeta,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: sub,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      decoration: TextDecoration.none,
                                    ),
                                  ),
                                ),
                              ),
                              Align(
                                alignment: Alignment.centerRight,
                                child: SolidCapsuleActionBar(
                                  padding: const EdgeInsets.all(8),
                                  children: [
                                    SolidCapsuleActionButton(
                                      tooltip: '닫기',
                                      icon: Icons.close_rounded,
                                      onPressed: () => Navigator.of(ctx).pop(),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: maxHeight - chrome - 32,
                          ),
                          child: ListView(
                            shrinkWrap: true,
                            padding: EdgeInsets.zero,
                            physics: const ClampingScrollPhysics(),
                            children: [
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  color: card,
                                  borderRadius: BorderRadius.circular(28),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 24,
                                    vertical: 18,
                                  ),
                                  child: body.isEmpty
                                      ? Text(
                                          '본문이 없어요.',
                                          style: TextStyle(
                                            color: sub,
                                            fontSize: 15,
                                            height: 1.45,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        )
                                      : LatexTextRenderer(
                                          body,
                                          dollarMath: true,
                                          style: TextStyle(
                                            color: text,
                                            fontSize: 15,
                                            height: 1.45,
                                            fontWeight: FontWeight.w500,
                                          ),
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          blockVerticalPadding: 6,
                                        ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
