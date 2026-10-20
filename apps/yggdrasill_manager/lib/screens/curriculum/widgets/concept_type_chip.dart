import 'package:flutter/material.dart';

import '../../think/think_style.dart';

/// 개념 유형의 색·앞 글자. 기본 다섯 유형만 색이 있고, 새로 받아들인 유형·유형 없음은 회색이다.
/// 디자인: docs/design-system.md (개념 유형 칩)
class ConceptTypeStyle {
  const ConceptTypeStyle(this.label, this.glyph, this.color);

  final String label;
  final String glyph;
  final Color color;

  Color get foreground => Color.lerp(color, Colors.white, 0.4)!;
}

const Color kConceptDefinition = Color(0xFFDE6A73);
const Color kConceptNotation = Color(0xFFB39DDB);
const Color kConceptCaution = Color(0xFFEAB968);
const Color kConceptProperty = Color(0xFF7AA9E6);
const Color kConceptMethod = Color(0xFF7CC67C);

const Map<String, ConceptTypeStyle> _known = {
  '정의': ConceptTypeStyle('정의', '정', kConceptDefinition),
  '표현': ConceptTypeStyle('표현', '표', kConceptNotation),
  '주의': ConceptTypeStyle('주의', '주', kConceptCaution),
  '성질': ConceptTypeStyle('성질', '성', kConceptProperty),
  '방법': ConceptTypeStyle('방법', '방', kConceptMethod),
};

const ConceptTypeStyle kConceptNoType = ConceptTypeStyle('유형 없음', '?', kThinkSub);

ConceptTypeStyle conceptTypeStyle(String? name) {
  final n = (name ?? '').trim();
  if (n.isEmpty) return kConceptNoType;
  return _known[n] ?? ConceptTypeStyle(n, n.characters.first, kThinkSub);
}

class ConceptTypeGlyph extends StatelessWidget {
  const ConceptTypeGlyph(this.style, {super.key});

  final ConceptTypeStyle style;

  @override
  Widget build(BuildContext context) {
    const size = 18.0;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: style.color.withValues(alpha: 0.24), shape: BoxShape.circle),
      child: Text(style.glyph,
          style: TextStyle(color: style.color, fontSize: size * 0.56, fontWeight: FontWeight.w800, height: 1)),
    );
  }
}

/// 개념 칩: 유형 글자 + 이름. 유형 색을 옅게 채우고, 열어 둔 개념·Think 참고만 테두리를 그린다.
class ConceptTypeChip extends StatefulWidget {
  const ConceptTypeChip({
    super.key,
    required this.name,
    required this.style,
    this.version,
    this.statements = 1,
    this.review = false,
    this.tooltip,
    this.opened = false,
    this.picked = false,
    this.dimmed = false,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTapDown,
  });

  final String name;
  final ConceptTypeStyle style;
  final String? version;

  /// 기본 서술을 포함한 서술 수. 2 이상일 때만 이름 뒤에 표시한다.
  final int statements;

  /// 같은 개념인지 판단이 남은 "검토 필요" 개념.
  final bool review;
  final String? tooltip;
  final bool opened;
  final bool picked;
  final bool dimmed;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final GestureTapDownCallback? onSecondaryTapDown;

  @override
  State<ConceptTypeChip> createState() => _ConceptTypeChipState();
}

class _ConceptTypeChipState extends State<ConceptTypeChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.style;
    final fg = s.foreground;
    final ring = widget.opened || widget.picked;
    final version = (widget.version ?? '').trim();
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 160),
      opacity: widget.dimmed ? 0.28 : 1,
      child: Tooltip(
        message: widget.tooltip ?? '${s.label} · ${widget.name}',
        waitDuration: const Duration(milliseconds: 400),
        child: MouseRegion(
          cursor: widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            onSecondaryTapDown: widget.onSecondaryTapDown,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              height: 30,
              padding: const EdgeInsets.only(left: 6, right: 12),
              decoration: BoxDecoration(
                color: s.color.withValues(alpha: widget.opened ? 0.26 : (_hover ? 0.18 : 0.10)),
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: ring ? s.color.withValues(alpha: 0.9) : Colors.transparent),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ConceptTypeGlyph(s),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(widget.name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: fg, fontSize: 13, fontWeight: FontWeight.w600)),
                  ),
                  if (version.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    Text(version,
                        style: TextStyle(color: fg.withValues(alpha: 0.6), fontSize: 11, fontWeight: FontWeight.w700)),
                  ],
                  if (widget.statements > 1) ...[
                    const SizedBox(width: 6),
                    ConceptStatementCountMark(widget.statements, color: fg.withValues(alpha: 0.6)),
                  ],
                  if (widget.review) ...[
                    const SizedBox(width: 6),
                    const ConceptReviewMark(),
                  ],
                  if (widget.picked) ...[
                    const SizedBox(width: 4),
                    Icon(Icons.forum_rounded, size: 14, color: s.color),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 서술이 여럿인 개념 표시: 겹 아이콘 12 + 수 11 w700.
class ConceptStatementCountMark extends StatelessWidget {
  const ConceptStatementCountMark(this.count, {super.key, required this.color});

  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.layers_outlined, size: 12, color: color),
        const SizedBox(width: 2),
        Text('$count', style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700)),
      ],
    );
  }
}

/// "검토 필요" 개념 표시: 깃발 12 `kThinkAccent`.
class ConceptReviewMark extends StatelessWidget {
  const ConceptReviewMark({super.key});

  @override
  Widget build(BuildContext context) => const Icon(Icons.flag_rounded, size: 12, color: kThinkAccent);
}

/// 목록 보기의 유형 꼬리표(이름 앞 36×20).
class ConceptTypeTag extends StatelessWidget {
  const ConceptTypeTag(this.style, {super.key});

  final ConceptTypeStyle style;

  @override
  Widget build(BuildContext context) {
    final label = style.label.characters.length > 3 ? style.label.characters.take(2).toString() : style.label;
    return Container(
      width: 36,
      height: 20,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: style.color.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(6)),
      child: Text(label, style: TextStyle(color: style.color, fontSize: 11, fontWeight: FontWeight.w800, height: 1)),
    );
  }
}

/// 폴더 안 유형 비율 막대(유형 순서대로).
class ConceptTypeBar extends StatelessWidget {
  const ConceptTypeBar({super.key, required this.counts, this.width = 48});

  /// 유형 순서대로 (스타일, 개수).
  final List<(ConceptTypeStyle, int)> counts;
  final double width;

  @override
  Widget build(BuildContext context) {
    final shown = [
      for (final c in counts)
        if (c.$2 > 0) c
    ];
    if (shown.isEmpty) return SizedBox(width: width);
    return Tooltip(
      message: [for (final c in shown) '${c.$1.label} ${c.$2}'].join(' · '),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: SizedBox(
          width: width,
          height: 4,
          child: Row(children: [for (final c in shown) Expanded(flex: c.$2, child: ColoredBox(color: c.$1.color))]),
        ),
      ),
    );
  }
}

class ConceptTypeFilterChip extends StatelessWidget {
  const ConceptTypeFilterChip({
    super.key,
    required this.style,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final ConceptTypeStyle style;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(15),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: 30,
          padding: const EdgeInsets.only(left: 6, right: 12),
          decoration: BoxDecoration(
            color: selected ? style.color.withValues(alpha: 0.16) : Colors.transparent,
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: selected ? style.color.withValues(alpha: 0.6) : kThinkBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConceptTypeGlyph(style),
              const SizedBox(width: 8),
              Text(style.label,
                  style:
                      TextStyle(color: selected ? kThinkText : kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(width: 4),
              Text('$count', style: const TextStyle(color: kThinkHint, fontSize: 12, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ),
    );
  }
}
