import 'package:flutter/material.dart';

import '../screens/design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';

const double sharedFolderTreePanelWidthMin = 220;
const double sharedFolderTreePanelWidthMax = 330;
const double sharedFolderTreeItemSpacing = 4;
const double sharedFolderTreeTitleListGap = 20;
const double sharedFolderTreeNavRowPaddingVertical = 12;
const double sharedFolderTreeLeadingWidth = 18.0;
const Duration sharedFolderTreeExpandDuration = Duration(milliseconds: 220);
const Curve sharedFolderTreeExpandCurve = Curves.easeOutCubic;

double sharedFolderTreePanelWidthFor(BuildContext context) {
  final screenWidth = MediaQuery.sizeOf(context).width;
  const refMinScreen = 1024.0;
  const refMaxScreen = 1920.0;
  if (screenWidth <= refMinScreen) return sharedFolderTreePanelWidthMin;
  if (screenWidth >= refMaxScreen) return sharedFolderTreePanelWidthMax;
  final t = (screenWidth - refMinScreen) / (refMaxScreen - refMinScreen);
  return sharedFolderTreePanelWidthMin +
      t * (sharedFolderTreePanelWidthMax - sharedFolderTreePanelWidthMin);
}

enum SharedFolderTreeRowStyle {
  pill,
  section,
}

@immutable
class SharedFolderTreeNode {
  const SharedFolderTreeNode({
    required this.id,
    required this.label,
    this.icon = Icons.folder_outlined,
    this.selectedIcon,
    this.children = const <SharedFolderTreeNode>[],
    this.rowStyle = SharedFolderTreeRowStyle.pill,
    this.showDividerWhenCollapsed = false,
    this.showDividerAfter = false,
    this.data,
  });

  final String id;
  final String label;
  final IconData icon;
  final IconData? selectedIcon;
  final List<SharedFolderTreeNode> children;
  final SharedFolderTreeRowStyle rowStyle;
  final bool showDividerWhenCollapsed;
  final bool showDividerAfter;
  final Object? data;
}

typedef SharedFolderTreeNodeTap = void Function(SharedFolderTreeNode node);
typedef SharedFolderTreeNodeBuilder = Widget Function(
  BuildContext context,
  SharedFolderTreeNode node,
  int depth,
  Widget row,
);

class SharedFolderTreePanel extends StatelessWidget {
  const SharedFolderTreePanel({
    super.key,
    required this.title,
    required this.nodes,
    required this.selectedNodeId,
    required this.expandedNodeIds,
    required this.onNodeTap,
    required this.onToggleExpanded,
    this.trailingNodes = const <SharedFolderTreeNode>[],
    this.subtitle,
    this.emptyMessage,
    this.isLoading = false,
    this.accentColor = const Color(0xFF33A373),
    this.listBottomPadding = 8,
    this.wrapNodeRow,
    this.titleTrailing,
    this.reserveTitleTrailingSlot = false,
    this.reserveSubtitleSlot = false,
    this.titleTrailingSlotFraction = 0.58,
  });

  final String title;
  final String? subtitle;
  final Widget? titleTrailing;
  final bool reserveTitleTrailingSlot;
  final bool reserveSubtitleSlot;
  final double titleTrailingSlotFraction;
  final List<SharedFolderTreeNode> nodes;
  final List<SharedFolderTreeNode> trailingNodes;
  final String? selectedNodeId;
  final Set<String> expandedNodeIds;
  final SharedFolderTreeNodeTap onNodeTap;
  final SharedFolderTreeNodeTap onToggleExpanded;
  final String? emptyMessage;
  final bool isLoading;
  final Color accentColor;
  final double listBottomPadding;
  final SharedFolderTreeNodeBuilder? wrapNodeRow;

  static const double _subtitleFontSize = 11;
  static const double _subtitleLineHeight = 1.35;
  static const double _subtitleSlotHeight =
      _subtitleFontSize * _subtitleLineHeight;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final panelStyle = FabTabBarTokens.previewAcademyPanelStyleFor(brightness);

    return DecoratedBox(
      decoration: PreviewAcademyGroupedFieldsCard.cardDecoration(
        panelStyle,
        brightness: brightness,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(
          FabTabBarTokens.previewAcademyGroupedCardRadius,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                FabTabBarTokens.previewAcademyGroupedRowPaddingHorizontal - 6,
                20,
                FabTabBarTokens.previewAcademyGroupedRowPaddingHorizontal,
                (subtitle != null || reserveSubtitleSlot)
                    ? 12
                    : sharedFolderTreeTitleListGap,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildTitleRow(panelStyle),
                  if (subtitle != null || reserveSubtitleSlot) ...[
                    const SizedBox(height: 6),
                    SizedBox(
                      height: _subtitleSlotHeight,
                      child: subtitle == null
                          ? const SizedBox.shrink()
                          : Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                subtitle!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: panelStyle.hint,
                                  fontSize: _subtitleFontSize,
                                  fontWeight: FontWeight.w600,
                                  height: _subtitleLineHeight,
                                ),
                              ),
                            ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ],
              ),
            ),
            Expanded(
              child: _buildBody(context, panelStyle, brightness),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTitleRow(PreviewAcademyPanelStyle panelStyle) {
    final titleStyle = TextStyle(
      color: panelStyle.title,
      fontWeight: FontWeight.w600,
      fontSize: FabTabBarTokens.fabBarLabelFontSize,
      height: 1.25,
    );
    final showTrailingSlot = titleTrailing != null || reserveTitleTrailingSlot;

    return LayoutBuilder(
      builder: (context, constraints) {
        final slotWidth = showTrailingSlot
            ? constraints.maxWidth * titleTrailingSlotFraction
            : 0.0;

        return SizedBox(
          height: 28,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: titleStyle,
              ),
              const Spacer(),
              if (slotWidth > 0)
                SizedBox(
                  width: slotWidth,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: titleTrailing ?? const SizedBox.shrink(),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBody(
    BuildContext context,
    PreviewAcademyPanelStyle panelStyle,
    Brightness brightness,
  ) {
    if (isLoading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (nodes.isEmpty && trailingNodes.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Text(
            emptyMessage ?? '표시할 항목이 없습니다.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: panelStyle.hint,
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
          ),
        ),
      );
    }

    return ListView(
      padding: EdgeInsets.only(bottom: listBottomPadding),
      children: [
        for (var i = 0; i < nodes.length; i++)
          _buildNode(
            context,
            panelStyle,
            brightness,
            nodes[i],
            0,
            isLastAmongSiblings: i == nodes.length - 1,
          ),
        if (nodes.isNotEmpty && trailingNodes.isNotEmpty)
          const SizedBox(height: sharedFolderTreeItemSpacing),
        for (final node in trailingNodes)
          _buildNode(
            context,
            panelStyle,
            brightness,
            node,
            0,
            isLastAmongSiblings: false,
          ),
      ],
    );
  }

  Widget _buildNode(
    BuildContext context,
    PreviewAcademyPanelStyle panelStyle,
    Brightness brightness,
    SharedFolderTreeNode node,
    int depth, {
    required bool isLastAmongSiblings,
  }) {
    final hasChildren = node.children.isNotEmpty;
    final isExpanded = expandedNodeIds.contains(node.id);
    final selected = selectedNodeId == node.id;
    final showDivider = node.showDividerAfter ||
        (node.showDividerWhenCollapsed && (!hasChildren || !isExpanded));

    final row = node.rowStyle == SharedFolderTreeRowStyle.section
        ? _buildSectionRow(
            context,
            panelStyle,
            brightness,
            node,
            selected: selected,
            hasChildren: hasChildren,
            isExpanded: isExpanded,
            showDivider: showDivider,
          )
        : _buildPillRow(
            context,
            panelStyle,
            brightness,
            node,
            depth: depth,
            selected: selected,
            hasChildren: hasChildren,
            isExpanded: isExpanded,
          );

    final wrappedRow = wrapNodeRow?.call(context, node, depth, row) ?? row;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        wrappedRow,
        if (hasChildren)
          AnimatedSize(
            duration: sharedFolderTreeExpandDuration,
            curve: sharedFolderTreeExpandCurve,
            alignment: Alignment.topCenter,
            clipBehavior: Clip.hardEdge,
            child: isExpanded
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < node.children.length; i++)
                        _buildNode(
                          context,
                          panelStyle,
                          brightness,
                          node.children[i],
                          depth + 1,
                          isLastAmongSiblings: i == node.children.length - 1,
                        ),
                    ],
                  )
                : const SizedBox(width: double.infinity),
          ),
        if (node.rowStyle != SharedFolderTreeRowStyle.section &&
            node.showDividerAfter &&
            isLastAmongSiblings)
          Divider(
            height: 1,
            thickness: 1,
            color: _dividerColor(brightness),
          ),
      ],
    );
  }

  Widget _buildSectionRow(
    BuildContext context,
    PreviewAcademyPanelStyle panelStyle,
    Brightness brightness,
    SharedFolderTreeNode node, {
    required bool selected,
    required bool hasChildren,
    required bool isExpanded,
    required bool showDivider,
  }) {
    final isDark = brightness == Brightness.dark;
    final labelColor = selected
        ? (isDark ? Colors.white : const Color(0xFF1A1A1A))
        : (isDark ? panelStyle.hint : const Color(0xFF666666));
    final chevronColor =
        isDark ? Colors.white.withOpacity(0.72) : const Color(0xFF1A1A1A);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            _rowOuterPaddingLeft(0),
            0,
            12,
            showDivider ? 0 : sharedFolderTreeItemSpacing,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => onNodeTap(node),
              hoverColor: Colors.transparent,
              splashColor: Colors.transparent,
              highlightColor: Colors.transparent,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: sharedFolderTreeNavRowPaddingVertical,
                ),
                child: Row(
                  children: [
                    const SizedBox(width: sharedFolderTreeLeadingWidth),
                    const SizedBox(width: 2),
                    Expanded(
                      child: Text(
                        node.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: labelColor,
                          fontWeight: FontWeight.w400,
                          fontSize: FabTabBarTokens.fabBarLabelFontSize,
                          letterSpacing: -0.1,
                        ),
                      ),
                    ),
                    if (hasChildren)
                      Icon(
                        isExpanded ? Icons.expand_more : Icons.chevron_right,
                        size: 20,
                        color: chevronColor,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (showDivider)
          Divider(height: 1, thickness: 1, color: _dividerColor(brightness)),
      ],
    );
  }

  Widget _buildPillRow(
    BuildContext context,
    PreviewAcademyPanelStyle panelStyle,
    Brightness brightness,
    SharedFolderTreeNode node, {
    required int depth,
    required bool selected,
    required bool hasChildren,
    required bool isExpanded,
  }) {
    final iconColor =
        selected ? accentColor : panelStyle.title.withOpacity(0.92);
    final labelColor = selected ? accentColor : panelStyle.title;
    final leftInset = depth * 10.0;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        _rowOuterPaddingLeft(leftInset),
        0,
        12,
        sharedFolderTreeItemSpacing,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => onNodeTap(node),
          borderRadius: BorderRadius.circular(999),
          hoverColor: Colors.transparent,
          splashColor: Colors.transparent,
          child: Ink(
            decoration: BoxDecoration(
              color: selected
                  ? FabTabBarTokens.fabHighlightPillFill(brightness)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(999),
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: sharedFolderTreeNavRowPaddingVertical,
            ),
            child: Row(
              children: [
                if (hasChildren)
                  InkWell(
                    onTap: () => onToggleExpanded(node),
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(
                        isExpanded ? Icons.expand_more : Icons.chevron_right,
                        size: 16,
                        color: panelStyle.icon,
                      ),
                    ),
                  )
                else
                  const SizedBox(width: sharedFolderTreeLeadingWidth),
                const SizedBox(width: 2),
                Icon(
                  selected ? (node.selectedIcon ?? node.icon) : node.icon,
                  size: 20,
                  color: iconColor,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    node.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: labelColor,
                      fontWeight: FontWeight.w600,
                      fontSize: FabTabBarTokens.fabBarLabelFontSize,
                      letterSpacing: -0.1,
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

  static double _rowOuterPaddingLeft(double leftInset) {
    return FabTabBarTokens.previewAcademyGroupedRowPaddingHorizontal -
        18 +
        leftInset;
  }

  static Color _dividerColor(Brightness brightness) {
    return brightness == Brightness.dark
        ? Colors.white.withOpacity(0.08)
        : const Color(0xFFE5E5E5);
  }
}
