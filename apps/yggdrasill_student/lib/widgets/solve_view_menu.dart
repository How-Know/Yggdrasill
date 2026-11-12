import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

/// 풀이 화면이 보여주는 세 가지 보기.
enum SolveViewKind {
  /// 번호 카드 목록.
  numbers,

  /// 문항 렌더링 이미지.
  question,

  /// 원본 교재 PDF.
  original,
}

/// Icons8 Menu Vertical. iOS (21618). 학습 앱 교재 보기 메뉴와 같은 아이콘.
const String _solveViewMenuSvg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 50 50"><path d="M 25 3 C 21.699219 3 19 5.699219 19 9 C 19 12.300781 21.699219 15 25 15 C 28.300781 15 31 12.300781 31 9 C 31 5.699219 28.300781 3 25 3 Z M 25 5 C 27.222656 5 29 6.777344 29 9 C 29 11.222656 27.222656 13 25 13 C 22.777344 13 21 11.222656 21 9 C 21 6.777344 22.777344 5 25 5 Z M 25 19 C 21.699219 19 19 21.699219 19 25 C 19 28.300781 21.699219 31 25 31 C 28.300781 31 31 28.300781 31 25 C 31 21.699219 28.300781 19 25 19 Z M 25 21 C 27.222656 21 29 22.777344 29 25 C 29 27.222656 27.222656 29 25 29 C 22.777344 29 21 27.222656 21 25 C 21 22.777344 22.777344 21 25 21 Z M 25 35 C 21.699219 35 19 37.699219 19 41 C 19 44.300781 21.699219 47 25 47 C 28.300781 47 31 44.300781 31 41 C 31 37.699219 28.300781 35 25 35 Z M 25 37 C 27.222656 37 29 38.777344 29 41 C 29 43.222656 27.222656 45 25 45 C 22.777344 45 21 43.222656 21 41 C 21 38.777344 22.777344 37 25 37 Z"/></svg>';

/// 페이지 버튼 왼쪽의 세로 점. 누르면 학습 앱 교재 보기 메뉴와 같은 드롭다운이 열린다.
class SolveViewMenuButton extends StatefulWidget {
  const SolveViewMenuButton({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final SolveViewKind selected;
  final ValueChanged<SolveViewKind> onSelected;

  @override
  State<SolveViewMenuButton> createState() => _SolveViewMenuButtonState();
}

class _SolveViewMenuButtonState extends State<SolveViewMenuButton> {
  final OverlayPortalController _overlay = OverlayPortalController();

  bool get _open => _overlay.isShowing;

  void _toggle() {
    if (_open) {
      _overlay.hide();
    } else {
      _overlay.show();
    }
    setState(() {});
  }

  void _close() {
    if (!_open) return;
    _overlay.hide();
    setState(() {});
  }

  void _choose(SolveViewKind kind) {
    _close();
    if (kind == widget.selected) return;
    widget.onSelected(kind);
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _overlay,
      overlayChildBuilder: (overlayContext, info) {
        final target = MatrixUtils.transformRect(
          info.childPaintTransform,
          Offset.zero & info.childSize,
        );
        final overlaySize = info.overlaySize;
        const panelMaxWidth = 280.0;
        const gap = 12.0;
        final panelWidth = math.min(panelMaxWidth, target.right - 12);
        final left = (target.right - panelWidth)
            .clamp(12.0, math.max(12.0, overlaySize.width - panelWidth - 12))
            .toDouble();
        final maxHeight = math.min(
          overlaySize.height * 0.4,
          math.max(0.0, overlaySize.height - target.bottom - gap - 16),
        );
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _close,
                child: const SizedBox.expand(),
              ),
            ),
            Positioned(
              left: left,
              top: target.bottom + gap,
              width: panelWidth,
              child: _SolveViewMenuPanel(
                maxHeight: maxHeight,
                selected: widget.selected,
                onClose: _close,
                onSelected: _choose,
              ),
            ),
          ],
        );
      },
      child: SolidCapsuleActionButton(
        tooltip: '보기',
        selected: _open,
        onPressed: _toggle,
        iconBuilder: (color, size) => SvgPicture.string(
          _solveViewMenuSvg,
          width: size,
          height: size,
          colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
        ),
      ),
    );
  }
}

class _SolveViewMenuPanel extends StatelessWidget {
  const _SolveViewMenuPanel({
    required this.maxHeight,
    required this.selected,
    required this.onClose,
    required this.onSelected,
  });

  final double maxHeight;
  final SolveViewKind selected;
  final VoidCallback onClose;
  final ValueChanged<SolveViewKind> onSelected;

  static const _radius = 28.0;
  static const _font = 'KakaoSmallSans';
  static const _fontSize = 16.0;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? Colors.white : Colors.black;
    final iconColor = isDark ? const Color(0xB3FFFFFF) : const Color(0xFF6B6B6B);
    final dividerColor =
        isDark ? const Color(0xFF38383A) : const Color(0xFFE5E5EA);
    final hover =
        isDark ? const Color(0x12FFFFFF) : const Color(0x14000000);

    final rows = <(String, SolveViewKind)>[
      ('번호 보기', SolveViewKind.numbers),
      ('문항 보기', SolveViewKind.question),
      ('원본 보기', SolveViewKind.original),
    ];

    final panel = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 12, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '보기',
                  style: TextStyle(
                    fontFamily: _font,
                    fontSize: _fontSize,
                    fontWeight: FontWeight.w800,
                    color: titleColor,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onClose,
                  borderRadius: BorderRadius.circular(999),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(
                      Icons.close_rounded,
                      size: 20,
                      color: iconColor,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Divider(color: dividerColor, height: 1),
        const SizedBox(height: 6),
        for (final row in rows)
          _SolveViewMenuRow(
            label: row.$1,
            checked: selected == row.$2,
            titleColor: titleColor,
            hover: hover,
            onTap: () => onSelected(row.$2),
          ),
        const SizedBox(height: 6),
      ],
    );

    final radius = BorderRadius.circular(_radius);
    final shell = isDark
        ? DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFF121212),
              borderRadius: radius,
              border: Border.all(color: const Color(0x1AFFFFFF), width: 0.5),
            ),
            child: panel,
          )
        : DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: const Color(0x40FFFFFF), width: 0.5),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x24000000),
                  blurRadius: 4,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: radius,
              clipBehavior: Clip.antiAlias,
              child: ColoredBox(
                color: const Color(0xE6FFFFFF),
                child: panel,
              ),
            ),
          );

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Material(
        type: MaterialType.transparency,
        child: DefaultTextStyle(
          style: const TextStyle(
            decoration: TextDecoration.none,
            decorationColor: Colors.transparent,
          ),
          child: shell,
        ),
      ),
    );
  }
}

class _SolveViewMenuRow extends StatefulWidget {
  const _SolveViewMenuRow({
    required this.label,
    required this.checked,
    required this.titleColor,
    required this.hover,
    required this.onTap,
  });

  final String label;
  final bool checked;
  final Color titleColor;
  final Color hover;
  final VoidCallback onTap;

  @override
  State<_SolveViewMenuRow> createState() => _SolveViewMenuRowState();
}

class _SolveViewMenuRowState extends State<_SolveViewMenuRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: ColoredBox(
          color: _hovered ? widget.hover : Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 20,
                  child: widget.checked
                      ? const Padding(
                          padding: EdgeInsets.only(top: 3),
                          child: Icon(
                            Icons.check_rounded,
                            size: 20,
                            color: YggGlassTokens.confirmActionColor,
                          ),
                        )
                      : null,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.label,
                    style: TextStyle(
                      fontFamily: _SolveViewMenuPanel._font,
                      fontSize: _SolveViewMenuPanel._fontSize,
                      fontWeight:
                          widget.checked ? FontWeight.w700 : FontWeight.w600,
                      color: widget.titleColor,
                      decoration: TextDecoration.none,
                    ),
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
