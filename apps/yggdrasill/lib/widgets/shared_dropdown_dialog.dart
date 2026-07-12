import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../screens/design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';
import 'solid_capsule_action_bar.dart';

/// 앵커 버튼 아래에 펼쳐지는 공용 드롭다운 다이얼로그(글래스 패널) 토큰·셸·오버레이.
///
/// 문제은행 문항 필터 등에서 사용한다. 트리거는 [child]로 두고,
/// 패널 내용은 [panelBuilder]로 구성한다.
class SharedDropdownDialog extends StatefulWidget {
  const SharedDropdownDialog({
    super.key,
    required this.childBuilder,
    required this.panelBuilder,
    this.disabled = false,
    this.panelMaxWidth = SharedDropdownDialogPanel.defaultMaxWidth,
    this.alignPanelRightToCapsuleBar = false,
    this.openPanelAboveAnchor = false,
    this.capsuleBarRightPadding = 14,
    this.panelRightExtraOffset = 0,
    this.maxHeightScreenFraction = 2 / 3,
  });

  final Widget Function(
    BuildContext context,
    SharedDropdownDialogPanelController controller,
  ) childBuilder;
  final Widget Function(
    BuildContext context,
    SharedDropdownDialogPanelController controller,
  ) panelBuilder;
  final bool disabled;
  final double panelMaxWidth;
  final bool alignPanelRightToCapsuleBar;
  /// true면 앵커 위쪽으로 패널을 펼친다(하단 FAB 등).
  final bool openPanelAboveAnchor;
  final double capsuleBarRightPadding;
  /// 같은 캡슐 바 안 오른쪽 형제 버튼 너비 등 추가 오프셋.
  final double panelRightExtraOffset;
  final double maxHeightScreenFraction;

  @override
  State<SharedDropdownDialog> createState() => _SharedDropdownDialogState();
}

class _SharedDropdownDialogState extends State<SharedDropdownDialog> {
  final OverlayPortalController _overlayController = OverlayPortalController();

  bool get _isOpen => _overlayController.isShowing;

  void _toggleOverlay() {
    if (widget.disabled) return;
    if (_isOpen) {
      _overlayController.hide();
    } else {
      _overlayController.show();
    }
    setState(() {});
  }

  void _closeOverlay() {
    if (!_isOpen) return;
    _overlayController.hide();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final controller = SharedDropdownDialogPanelController(
      isOpen: _isOpen,
      close: _closeOverlay,
      toggle: _toggleOverlay,
    );

    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _overlayController,
      overlayChildBuilder: (overlayContext, info) {
        final targetRect = MatrixUtils.transformRect(
          info.childPaintTransform,
          Offset.zero & info.childSize,
        );
        final overlaySize = info.overlaySize;
        final panelRightEdge = (widget.alignPanelRightToCapsuleBar
                ? targetRect.right + widget.capsuleBarRightPadding
                : targetRect.right) +
            widget.panelRightExtraOffset;
        final panelWidth = math.min(
          widget.panelMaxWidth,
          panelRightEdge - 12,
        );
        final left = (panelRightEdge - panelWidth)
            .clamp(12.0, overlaySize.width - panelWidth - 12);
        final panelGap = FabTabBarTokens.previewAcademyMenuTopOffsetFromArrow;
        final maxPanelHeight = widget.openPanelAboveAnchor
            ? math.min(
                overlaySize.height * widget.maxHeightScreenFraction,
                math.max(0.0, targetRect.top - panelGap - 16),
              )
            : math.min(
                overlaySize.height * widget.maxHeightScreenFraction,
                overlaySize.height - targetRect.bottom - panelGap - 16,
              );

        final panel = Material(
          color: Colors.transparent,
          child: widget.panelBuilder(
            overlayContext,
            controller.copyWith(maxHeight: maxPanelHeight),
          ),
        );

        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _closeOverlay,
              ),
            ),
            if (widget.openPanelAboveAnchor)
              Positioned(
                left: left,
                bottom: overlaySize.height - targetRect.top + panelGap,
                width: panelWidth,
                child: panel,
              )
            else
              Positioned(
                left: left,
                top: targetRect.bottom + panelGap,
                width: panelWidth,
                child: panel,
              ),
          ],
        );
      },
      child: widget.childBuilder(context, controller),
    );
  }
}

/// [SharedDropdownDialog] 패널에서 닫기·토글·최대 높이를 전달한다.
class SharedDropdownDialogPanelController {
  const SharedDropdownDialogPanelController({
    required this.isOpen,
    required this.close,
    required this.toggle,
    this.maxHeight = double.infinity,
  });

  final bool isOpen;
  final VoidCallback close;
  final VoidCallback toggle;
  final double maxHeight;

  SharedDropdownDialogPanelController copyWith({
    bool? isOpen,
    VoidCallback? close,
    VoidCallback? toggle,
    double? maxHeight,
  }) {
    return SharedDropdownDialogPanelController(
      isOpen: isOpen ?? this.isOpen,
      close: close ?? this.close,
      toggle: toggle ?? this.toggle,
      maxHeight: maxHeight ?? this.maxHeight,
    );
  }
}

/// 공용 드롭다운 다이얼로그 패널 셸 — 타이틀·초기화·닫기·디바이더·본문.
class SharedDropdownDialogPanel extends StatelessWidget {
  const SharedDropdownDialogPanel({
    super.key,
    required this.title,
    required this.body,
    required this.maxHeight,
    required this.onClose,
    this.onReset,
    this.resetEnabled = false,
    this.resetLabel = '초기화',
    this.resetIcon = Icons.restart_alt_rounded,
    this.titleTrailing,
  });

  static const double defaultMaxWidth = 680;
  static const double horizontalInset = 18;
  static const double contentFontSize = 16;
  static const double headerBlockHeight = 61;
  static const EdgeInsets headerPadding =
      EdgeInsets.fromLTRB(horizontalInset, 12, horizontalInset - 6, 12);
  static const EdgeInsets bodyPadding =
      EdgeInsets.fromLTRB(horizontalInset, 12, horizontalInset, 12);

  final String title;
  final Widget body;
  final double maxHeight;
  final VoidCallback onClose;
  final VoidCallback? onReset;
  final bool resetEnabled;
  final String resetLabel;
  final IconData resetIcon;
  final Widget? titleTrailing;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    final style = FabTabBarTokens.previewAcademyPanelStyleFor(brightness);
    final palette = FabTabBarTokens.paletteFor(brightness);
    final glassTint = isDark
        ? FabTabBarTokens.previewAcademyMenuGlassTintDark
        : FabTabBarTokens.previewAcademyMenuGlassTintLight;
    final radius = BorderRadius.circular(
      FabTabBarTokens.previewAcademyMenuRadius,
    );
    final resetColor = resetEnabled
        ? FabTabBarTokens.previewConfirmActionColor
        : style.hint;
    final bodyMaxHeight = math.max(0.0, maxHeight - headerBlockHeight);

    final panelContent = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: headerPadding,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: FabTabBarTokens.previewMenuItemTextStyle(style)
                      .copyWith(
                    fontSize: contentFontSize,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (titleTrailing != null) titleTrailing!,
              if (onReset != null)
                TextButton.icon(
                  onPressed: resetEnabled ? onReset : null,
                  style: TextButton.styleFrom(
                    foregroundColor: resetColor,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: Icon(resetIcon, size: 16, color: resetColor),
                  label: Text(
                    resetLabel,
                    style: FabTabBarTokens.previewAcademyLabelStyle(style)
                        .copyWith(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: resetColor,
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
                      color: style.icon,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Divider(color: style.divider, height: 1),
        Flexible(
          fit: FlexFit.loose,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: bodyMaxHeight),
            child: body,
          ),
        ),
      ],
    );

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Material(
        type: MaterialType.transparency,
        color: Colors.transparent,
        child: DefaultTextStyle(
          style: const TextStyle(
            decoration: TextDecoration.none,
            decorationColor: Colors.transparent,
          ),
          child: isDark
              ? DecoratedBox(
                  decoration: BoxDecoration(
                    color: style.groupedCardBackground,
                    borderRadius: radius,
                    border: FabTabBarTokens.groupedCardBorderFor(brightness),
                  ),
                  child: panelContent,
                )
              : DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    border: Border.all(
                      color: const Color(0x40FFFFFF),
                      width: 0.5,
                    ),
                    boxShadow: palette.boxShadows,
                  ),
                  child: ClipRRect(
                    borderRadius: radius,
                    clipBehavior: Clip.antiAlias,
                    child: ColoredBox(
                      color: glassTint,
                      child: panelContent,
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

/// 공용 드롭다운 패널 본문 — 섹션 제목 + 항목 목록.
class SharedDropdownDialogSection extends StatelessWidget {
  const SharedDropdownDialogSection({
    super.key,
    required this.title,
    required this.style,
    required this.hoverOverlay,
    required this.children,
    this.emptyMessage,
  });

  final String title;
  final PreviewAcademyPanelStyle style;
  final Color hoverOverlay;
  final List<Widget> children;
  final String? emptyMessage;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            SharedDropdownDialogPanel.horizontalInset,
            12,
            SharedDropdownDialogPanel.horizontalInset,
            4,
          ),
          child: Text(
            title,
            style: FabTabBarTokens.previewAcademyLabelStyle(style).copyWith(
              fontSize: SharedDropdownDialogPanel.contentFontSize,
              fontWeight: FontWeight.w800,
              color: style.label,
            ),
          ),
        ),
        if (children.isEmpty && emptyMessage != null)
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: SharedDropdownDialogPanel.horizontalInset,
              vertical: 8,
            ),
            child: Text(
              emptyMessage!,
              style: FabTabBarTokens.previewBodyTextStyle(
                style,
                color: style.hint,
                fontWeight: FontWeight.w600,
              ).copyWith(fontSize: SharedDropdownDialogPanel.contentFontSize),
            ),
          )
        else
          ...children,
      ],
    );
  }
}

/// 공용 드롭다운 패널 — 체크 가능한 메뉴 행.
class SharedDropdownDialogMenuRow extends StatefulWidget {
  const SharedDropdownDialogMenuRow({
    super.key,
    required this.selected,
    required this.style,
    required this.hoverOverlay,
    required this.onTap,
    required this.child,
  });

  final bool selected;
  final PreviewAcademyPanelStyle style;
  final Color hoverOverlay;
  final VoidCallback onTap;
  final Widget child;

  @override
  State<SharedDropdownDialogMenuRow> createState() =>
      _SharedDropdownDialogMenuRowState();
}

class _SharedDropdownDialogMenuRowState extends State<SharedDropdownDialogMenuRow> {
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
          color: _hovered ? widget.hoverOverlay : Colors.transparent,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: SharedDropdownDialogPanel.horizontalInset,
              vertical: 10,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 24,
                  child: widget.selected
                      ? Icon(
                          Icons.check_rounded,
                          size: SharedDropdownDialogPanel.contentFontSize,
                          color: widget.style.title,
                        )
                      : null,
                ),
                Expanded(child: widget.child),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 공용 드롭다운 패널 본문 — 세로 구분선이 있는 2열 레이아웃.
class SharedDropdownDialogSplitBody extends StatelessWidget {
  const SharedDropdownDialogSplitBody({
    super.key,
    required this.leading,
    required this.trailing,
    this.leadingFlex = 3,
    this.trailingFlex = 2,
    this.columnGap = 12,
  });

  final Widget leading;
  final Widget trailing;
  final int leadingFlex;
  final int trailingFlex;
  final double columnGap;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final dividerColor =
        FabTabBarTokens.previewAcademyPanelStyleFor(brightness).divider;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: leadingFlex,
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 4),
            child: leading,
          ),
        ),
        SizedBox(width: columnGap),
        Container(width: 1, color: dividerColor),
        Expanded(
          flex: trailingFlex,
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 4),
            child: trailing,
          ),
        ),
      ],
    );
  }
}
