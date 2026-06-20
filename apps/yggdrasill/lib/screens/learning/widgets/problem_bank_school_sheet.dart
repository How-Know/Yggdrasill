import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';
import '../../../services/learning_problem_bank_service.dart';
import '../../../widgets/shared_folder_tree.dart';

/// 왼쪽 패널: 내신 기출(`school_past`)은 학교 → 연도 → 문서, 그 외 출처는 평면 목록.
class ProblemBankSchoolSheet extends StatefulWidget {
  const ProblemBankSchoolSheet({
    super.key,
    required this.sidebarRevision,
    required this.selectedSourceTypeCode,
    required this.documents,
    required this.selectedDocumentId,
    required this.onDocumentSelected,
    required this.isLoading,
    this.privateMaterialUnits = const <ProblemBankPrivateMaterialBigNode>[],
    this.selectedPrivateMaterialPageKeys = const <String>{},
    this.onPrivateMaterialPageToggled,
    this.onPrivateMaterialPageKeysToggled,
    this.privateMaterialTitle = '',
    this.privateMaterialEmptyMessage = '교재를 선택한 뒤 페이지를 체크해 주세요.',
    this.privateMaterialTreeEnabled = true,
    this.onPrivateMaterialCleared,
  });

  /// 필터 등으로 문서 목록이 갱신될 때마다 증가 — 펼침 상태 초기화용.
  final int sidebarRevision;
  final String selectedSourceTypeCode;
  final List<LearningProblemDocumentSummary> documents;
  final String? selectedDocumentId;
  final ValueChanged<String> onDocumentSelected;
  final bool isLoading;
  final List<ProblemBankPrivateMaterialBigNode> privateMaterialUnits;
  final Set<String> selectedPrivateMaterialPageKeys;
  final void Function(String pageKey, bool selected)?
      onPrivateMaterialPageToggled;
  final void Function(Iterable<String> pageKeys, bool selected)?
      onPrivateMaterialPageKeysToggled;
  final String privateMaterialTitle;
  final String privateMaterialEmptyMessage;
  final bool privateMaterialTreeEnabled;
  final VoidCallback? onPrivateMaterialCleared;

  @override
  State<ProblemBankSchoolSheet> createState() => _ProblemBankSchoolSheetState();
}

class _ProblemBankSchoolSheetState extends State<ProblemBankSchoolSheet> {
  static const _unspecifiedSchool = '학교 미지정';
  static const Color _checkboxActive = Color(0xFF33A373);

  final Set<String> _expandedTreeNodeIds = <String>{};
  bool _privatePageDragActive = false;
  bool _privatePageDragSelectMode = true;
  bool _privatePageSuppressNextTap = false;
  Set<String> _privatePageDragBaseKeys = <String>{};
  final Set<String> _privatePageDragKeys = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _expandForSelectedDocument();
        _expandDefaultPrivateMaterialNodes();
      }
    });
  }

  @override
  void didUpdateWidget(covariant ProblemBankSchoolSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sidebarRevision != widget.sidebarRevision) {
      _expandedTreeNodeIds.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _expandForSelectedDocument();
          _expandDefaultPrivateMaterialNodes();
        }
      });
    } else if (oldWidget.selectedDocumentId != widget.selectedDocumentId ||
        oldWidget.documents != widget.documents ||
        oldWidget.privateMaterialUnits != widget.privateMaterialUnits ||
        oldWidget.selectedSourceTypeCode != widget.selectedSourceTypeCode ||
        oldWidget.privateMaterialTreeEnabled !=
            widget.privateMaterialTreeEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _expandForSelectedDocument();
          if (oldWidget.privateMaterialUnits != widget.privateMaterialUnits ||
              oldWidget.selectedSourceTypeCode !=
                  widget.selectedSourceTypeCode) {
            _expandDefaultPrivateMaterialNodes();
          }
        }
      });
    }
  }

  void _expandDefaultPrivateMaterialNodes() {
    if (widget.selectedSourceTypeCode != 'private_material') return;
    if (!widget.privateMaterialTreeEnabled) return;
    if (widget.privateMaterialUnits.isEmpty) return;
    final big = widget.privateMaterialUnits.first;
    setState(() {
      _expandedTreeNodeIds.add(_privateBigId(big, 0));
      for (final mid in big.mids) {
        _expandedTreeNodeIds.add(_privateMidId(mid));
        for (final small in mid.smalls) {
          _expandedTreeNodeIds.add(_privateSmallId(small));
        }
      }
    });
  }

  void _expandForSelectedDocument() {
    final id = widget.selectedDocumentId?.trim();
    if (id == null || id.isEmpty) return;
    for (final doc in widget.documents) {
      if (doc.id != id) continue;
      final school = _schoolLabel(doc);
      final yearLabel = _yearLabel(doc);
      final yearKey = '$school|$yearLabel';
      setState(() {
        _expandedTreeNodeIds.add('school:$school');
        _expandedTreeNodeIds.add('year:$yearKey');
      });
      return;
    }
  }

  static String _schoolLabel(LearningProblemDocumentSummary d) {
    final s = d.schoolName.trim();
    return s.isEmpty ? _unspecifiedSchool : s;
  }

  static String _yearLabel(LearningProblemDocumentSummary d) {
    final y = d.examYear;
    return y != null ? '$y' : '미지정';
  }

  static Map<String, Map<String, List<LearningProblemDocumentSummary>>>
      _groupBySchoolThenYear(List<LearningProblemDocumentSummary> docs) {
    final out = <String, Map<String, List<LearningProblemDocumentSummary>>>{};
    for (final d in docs) {
      final school = _schoolLabel(d);
      final year = _yearLabel(d);
      out.putIfAbsent(school, () => {});
      out[school]!.putIfAbsent(year, () => []);
      out[school]![year]!.add(d);
    }
    return out;
  }

  static List<String> _sortedSchools(Iterable<String> schools) {
    final list = schools.toList();
    list.sort((a, b) {
      if (a == _unspecifiedSchool && b != _unspecifiedSchool) return 1;
      if (b == _unspecifiedSchool && a != _unspecifiedSchool) return -1;
      return a.compareTo(b);
    });
    return list;
  }

  static List<String> _sortedYears(Iterable<String> years) {
    final list = years.toList();
    list.sort((a, b) {
      if (a == '미지정' && b != '미지정') return 1;
      if (b == '미지정' && a != '미지정') return -1;
      final ia = int.tryParse(a);
      final ib = int.tryParse(b);
      if (ia != null && ib != null) return ib.compareTo(ia);
      return b.compareTo(a);
    });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return _buildTreePanel(context);
  }

  String _treePanelTitle() {
    switch (widget.selectedSourceTypeCode) {
      case 'school_past':
        return '내신 기출';
      case 'private_material':
        return '사설 교재';
      default:
        return '추출 문서';
    }
  }

  String? _treePanelSubtitle() {
    if (widget.selectedSourceTypeCode == 'private_material') {
      if (!widget.privateMaterialTreeEnabled) {
        return '오른쪽에서 교재를 선택해 주세요.';
      }
      return null;
    }
    if (widget.selectedSourceTypeCode == 'school_past') {
      return null;
    }
    return '학교·연도 폴더는 내신 기출 출처에서만 사용됩니다.';
  }

  Widget _buildTreePanel(BuildContext context) {
    final isPrivateMaterial =
        widget.selectedSourceTypeCode == 'private_material';
    final treeEnabled = !isPrivateMaterial || widget.privateMaterialTreeEnabled;
    final panel = SharedFolderTreePanel(
      title: _treePanelTitle(),
      subtitle: _treePanelSubtitle(),
      titleTrailing: _buildPrivateMaterialTitleChip(context),
      reserveTitleTrailingSlot:
          widget.selectedSourceTypeCode == 'private_material',
      reserveSubtitleSlot: widget.selectedSourceTypeCode == 'private_material',
      nodes: treeEnabled ? _buildTreeNodes() : const <SharedFolderTreeNode>[],
      selectedNodeId: isPrivateMaterial ? null : widget.selectedDocumentId,
      expandedNodeIds: _expandedTreeNodeIds,
      onNodeTap: _handleSharedTreeNodeTap,
      onToggleExpanded: _toggleSharedTreeNode,
      isLoading: treeEnabled && widget.isLoading,
      listBottomPadding: 116,
      emptyMessage: isPrivateMaterial
          ? (treeEnabled
              ? widget.privateMaterialEmptyMessage
              : '오른쪽에서 교재를 선택해 주세요.')
          : '조건에 맞는 추출 문서가 없습니다.',
      wrapNodeRow:
          isPrivateMaterial && treeEnabled ? _wrapPrivateMaterialNodeRow : null,
    );

    if (!isPrivateMaterial || !treeEnabled) return panel;

    return Listener(
      onPointerUp: (_) => _finishPrivatePageDrag(),
      onPointerCancel: (_) => _cancelPrivatePageDrag(),
      child: panel,
    );
  }

  Widget? _buildPrivateMaterialTitleChip(BuildContext context) {
    if (widget.selectedSourceTypeCode != 'private_material') return null;
    if (!widget.privateMaterialTreeEnabled) return null;
    final label = widget.privateMaterialTitle.trim();
    if (label.isEmpty) return null;
    if (widget.onPrivateMaterialCleared == null) return null;

    final brightness = Theme.of(context).brightness;
    final panelStyle = FabTabBarTokens.previewAcademyPanelStyleFor(brightness);
    final highlight = FabTabBarTokens.fabHighlightPillFill(brightness);

    return Material(
      color: Colors.transparent,
      child: SizedBox(
        width: double.infinity,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: highlight,
            borderRadius: BorderRadius.circular(999),
            border: FabTabBarTokens.groupedCardBorderFor(brightness),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 2, 2, 2),
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: panelStyle.title,
                      fontSize: FabTabBarTokens.fabBarLabelFontSize,
                      fontWeight: FontWeight.w600,
                      height: 1.25,
                      letterSpacing: -0.1,
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                InkWell(
                  onTap: widget.onPrivateMaterialCleared,
                  borderRadius: BorderRadius.circular(999),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(
                      Icons.close_rounded,
                      size: 16,
                      color: panelStyle.icon,
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

  List<SharedFolderTreeNode> _buildTreeNodes() {
    switch (widget.selectedSourceTypeCode) {
      case 'school_past':
        return _buildSchoolPastSharedTreeNodes();
      case 'private_material':
        return _buildPrivateMaterialSharedTreeNodes();
      default:
        return _buildFlatDocumentSharedTreeNodes();
    }
  }

  List<SharedFolderTreeNode> _buildFlatDocumentSharedTreeNodes() {
    return [
      for (final doc in widget.documents)
        SharedFolderTreeNode(
          id: doc.id,
          label: doc.displayTitle,
          icon: Icons.description_outlined,
          selectedIcon: Icons.picture_as_pdf_outlined,
          data: _ProblemBankTreeNodeMeta.document(doc),
        ),
    ];
  }

  List<SharedFolderTreeNode> _buildSchoolPastSharedTreeNodes() {
    final grouped = _groupBySchoolThenYear(widget.documents);
    final schools = _sortedSchools(grouped.keys);
    return [
      for (final school in schools)
        SharedFolderTreeNode(
          id: 'school:$school',
          label: school,
          rowStyle: SharedFolderTreeRowStyle.section,
          data: _ProblemBankTreeNodeMeta.school(school),
          children: [
            for (final year in _sortedYears(grouped[school]!.keys))
              SharedFolderTreeNode(
                id: 'year:$school|$year',
                label: year == '미지정' ? '연도 미지정' : '$year년',
                icon: Icons.folder_outlined,
                selectedIcon: Icons.folder,
                data: _ProblemBankTreeNodeMeta.year(school, year),
                children: [
                  for (final doc in grouped[school]![year]!)
                    SharedFolderTreeNode(
                      id: doc.id,
                      label: doc.displayTitle,
                      icon: Icons.description_outlined,
                      selectedIcon: Icons.picture_as_pdf_outlined,
                      data: _ProblemBankTreeNodeMeta.document(doc),
                    ),
                ],
              ),
          ],
        ),
    ];
  }

  void _handleSharedTreeNodeTap(SharedFolderTreeNode node) {
    final meta = node.data;
    if (meta is _ProblemBankTreeNodeMeta) {
      if (meta.kind == _ProblemBankTreeNodeKind.document &&
          meta.document != null) {
        widget.onDocumentSelected(meta.document!.id);
        return;
      }
      if (meta.kind == _ProblemBankTreeNodeKind.privatePage &&
          meta.page != null) {
        if (_privatePageSuppressNextTap) {
          setState(() => _privatePageSuppressNextTap = false);
          return;
        }
        final page = meta.page!;
        final selected = _isEffectivePrivatePageSelected(page.key);
        widget.onPrivateMaterialPageToggled?.call(page.key, !selected);
        return;
      }
      if (meta.kind == _ProblemBankTreeNodeKind.privateSmall &&
          meta.small != null) {
        final pageKeys =
            meta.small!.pages.map((page) => page.key).toList(growable: false);
        final allSelected = pageKeys.isNotEmpty &&
            pageKeys.every(widget.selectedPrivateMaterialPageKeys.contains);
        widget.onPrivateMaterialPageKeysToggled?.call(pageKeys, !allSelected);
        return;
      }
    }
    _toggleSharedTreeNode(node);
  }

  void _toggleSharedTreeNode(SharedFolderTreeNode node) {
    setState(() {
      if (_expandedTreeNodeIds.contains(node.id)) {
        _expandedTreeNodeIds.remove(node.id);
      } else {
        _expandedTreeNodeIds.add(node.id);
      }
    });
  }

  String _privateBigId(ProblemBankPrivateMaterialBigNode big, int index) =>
      'pm-big:${big.order}:$index:${big.title}';

  String _privateMidId(ProblemBankPrivateMaterialMidNode mid) =>
      'pm-mid:${mid.order}:${mid.title}';

  String _privateSmallId(ProblemBankPrivateMaterialSmallNode small) =>
      'pm-small:${small.key}';

  List<SharedFolderTreeNode> _buildPrivateMaterialSharedTreeNodes() {
    return [
      for (var bi = 0; bi < widget.privateMaterialUnits.length; bi++)
        SharedFolderTreeNode(
          id: _privateBigId(widget.privateMaterialUnits[bi], bi),
          label: widget.privateMaterialUnits[bi].title,
          rowStyle: SharedFolderTreeRowStyle.section,
          data: _ProblemBankTreeNodeMeta.privateBig(
            widget.privateMaterialUnits[bi],
          ),
          children: [
            for (final mid in widget.privateMaterialUnits[bi].mids)
              SharedFolderTreeNode(
                id: _privateMidId(mid),
                label: mid.title,
                icon: Icons.folder_outlined,
                selectedIcon: Icons.folder,
                data: _ProblemBankTreeNodeMeta.privateMid(mid),
                children: [
                  for (final small in mid.smalls)
                    SharedFolderTreeNode(
                      id: _privateSmallId(small),
                      label: small.title,
                      icon: Icons.folder_outlined,
                      selectedIcon: Icons.folder,
                      data: _ProblemBankTreeNodeMeta.privateSmall(small),
                      children: [
                        for (final page in small.pages)
                          SharedFolderTreeNode(
                            id: 'pm-page:${page.key}',
                            label:
                                '${page.displayPage}쪽 · ${page.questionCount}문항',
                            icon: Icons.description_outlined,
                            selectedIcon: Icons.check_circle_outline,
                            data: _ProblemBankTreeNodeMeta.privatePage(page),
                          ),
                      ],
                    ),
                ],
              ),
          ],
        ),
    ];
  }

  Widget _wrapPrivateMaterialNodeRow(
    BuildContext context,
    SharedFolderTreeNode node,
    int depth,
    Widget row,
  ) {
    final meta = node.data;
    if (meta is! _ProblemBankTreeNodeMeta) return row;
    if (meta.kind == _ProblemBankTreeNodeKind.privateSmall &&
        meta.small != null) {
      return _buildPrivateSmallTreeRow(context, node, depth, meta.small!);
    }
    if (meta.kind == _ProblemBankTreeNodeKind.privatePage &&
        meta.page != null) {
      return _buildPrivatePageTreeRow(context, node, depth, meta.page!);
    }
    return row;
  }

  double _treeRowOuterPaddingLeft(int depth) {
    return FabTabBarTokens.previewAcademyGroupedRowPaddingHorizontal -
        18 +
        depth * 10.0;
  }

  Widget _buildPrivateSmallTreeRow(
    BuildContext context,
    SharedFolderTreeNode node,
    int depth,
    ProblemBankPrivateMaterialSmallNode small,
  ) {
    final panelStyle = FabTabBarTokens.previewAcademyPanelStyleFor(
      Theme.of(context).brightness,
    );
    final pageKeys =
        small.pages.map((page) => page.key).toList(growable: false);
    final selected = pageKeys.isNotEmpty &&
        pageKeys.every(widget.selectedPrivateMaterialPageKeys.contains);
    final partiallySelected = !selected &&
        pageKeys.any(widget.selectedPrivateMaterialPageKeys.contains);
    final hasChildren = node.children.isNotEmpty;
    final isExpanded = _expandedTreeNodeIds.contains(node.id);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        _treeRowOuterPaddingLeft(depth),
        0,
        12,
        sharedFolderTreeItemSpacing,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onPrivateMaterialPageKeysToggled == null
              ? null
              : () => widget.onPrivateMaterialPageKeysToggled!(
                    pageKeys,
                    !selected,
                  ),
          borderRadius: BorderRadius.circular(999),
          hoverColor: Colors.transparent,
          splashColor: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: sharedFolderTreeNavRowPaddingVertical,
            ),
            child: Row(
              children: [
                if (hasChildren)
                  InkWell(
                    onTap: () => _toggleSharedTreeNode(node),
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
                Checkbox(
                  value: selected ? true : (partiallySelected ? null : false),
                  tristate: true,
                  visualDensity: VisualDensity.compact,
                  side: BorderSide(color: panelStyle.border),
                  activeColor: _checkboxActive,
                  onChanged: widget.onPrivateMaterialPageKeysToggled == null
                      ? null
                      : (value) => widget.onPrivateMaterialPageKeysToggled!(
                            pageKeys,
                            value == true,
                          ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    small.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? panelStyle.title : panelStyle.hint,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                      fontSize: FabTabBarTokens.fabBarLabelFontSize,
                      letterSpacing: -0.1,
                    ),
                  ),
                ),
                Text(
                  '${small.pages.length}쪽',
                  style: TextStyle(
                    color: panelStyle.label,
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPrivatePageTreeRow(
    BuildContext context,
    SharedFolderTreeNode node,
    int depth,
    ProblemBankPrivateMaterialPageNode page,
  ) {
    final panelStyle = FabTabBarTokens.previewAcademyPanelStyleFor(
      Theme.of(context).brightness,
    );
    final brightness = Theme.of(context).brightness;
    final selected = _isEffectivePrivatePageSelected(page.key);
    final highlighted = selected;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        _treeRowOuterPaddingLeft(depth),
        0,
        12,
        sharedFolderTreeItemSpacing,
      ),
      child: MouseRegion(
        onEnter: (_) => _enterPrivatePageDrag(page.key),
        child: Listener(
          onPointerDown: (event) {
            if (event.buttons == kPrimaryMouseButton) {
              _startPrivatePageDrag(page.key);
            }
          },
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: widget.onPrivateMaterialPageToggled == null
                  ? null
                  : () => _handleSharedTreeNodeTap(node),
              borderRadius: BorderRadius.circular(999),
              hoverColor: Colors.transparent,
              splashColor: Colors.transparent,
              child: Ink(
                decoration: BoxDecoration(
                  color: highlighted
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
                    const SizedBox(width: sharedFolderTreeLeadingWidth),
                    const SizedBox(width: 2),
                    IgnorePointer(
                      child: Checkbox(
                        value: selected,
                        visualDensity: VisualDensity.compact,
                        side: BorderSide(color: panelStyle.border),
                        activeColor: _checkboxActive,
                        onChanged: widget.onPrivateMaterialPageToggled == null
                            ? null
                            : (_) {},
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '${page.displayPage}쪽',
                        style: TextStyle(
                          color:
                              highlighted ? panelStyle.title : panelStyle.hint,
                          fontWeight:
                              highlighted ? FontWeight.w800 : FontWeight.w600,
                          fontSize: FabTabBarTokens.fabBarLabelFontSize,
                          letterSpacing: -0.1,
                        ),
                      ),
                    ),
                    Text(
                      '${page.questionCount}문항',
                      style: TextStyle(
                        color: panelStyle.label,
                        fontWeight: FontWeight.w700,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool _isEffectivePrivatePageSelected(String pageKey) {
    if (!_privatePageDragActive) {
      return widget.selectedPrivateMaterialPageKeys.contains(pageKey);
    }
    if (_privatePageDragKeys.contains(pageKey)) {
      return _privatePageDragSelectMode;
    }
    return _privatePageDragBaseKeys.contains(pageKey);
  }

  void _startPrivatePageDrag(String pageKey) {
    if (widget.onPrivateMaterialPageKeysToggled == null) return;
    final selected = _isEffectivePrivatePageSelected(pageKey);
    setState(() {
      _privatePageDragActive = true;
      _privatePageDragSelectMode = !selected;
      _privatePageDragBaseKeys =
          Set<String>.from(widget.selectedPrivateMaterialPageKeys);
      _privatePageDragKeys
        ..clear()
        ..add(pageKey);
    });
  }

  void _enterPrivatePageDrag(String pageKey) {
    if (!_privatePageDragActive) return;
    if (_privatePageDragKeys.contains(pageKey)) return;
    setState(() {
      _privatePageDragKeys.add(pageKey);
    });
  }

  void _finishPrivatePageDrag() {
    if (!_privatePageDragActive) return;
    final keys = List<String>.from(_privatePageDragKeys);
    final selected = _privatePageDragSelectMode;
    setState(() {
      _privatePageDragActive = false;
      _privatePageSuppressNextTap = true;
      _privatePageDragKeys.clear();
      _privatePageDragBaseKeys = <String>{};
    });
    if (keys.isNotEmpty) {
      widget.onPrivateMaterialPageKeysToggled?.call(keys, selected);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_privatePageSuppressNextTap) return;
      setState(() => _privatePageSuppressNextTap = false);
    });
  }

  void _cancelPrivatePageDrag() {
    if (!_privatePageDragActive) return;
    setState(() {
      _privatePageDragActive = false;
      _privatePageDragKeys.clear();
      _privatePageDragBaseKeys = <String>{};
    });
  }
}

enum _ProblemBankTreeNodeKind {
  school,
  year,
  document,
  privateBig,
  privateMid,
  privateSmall,
  privatePage,
}

class _ProblemBankTreeNodeMeta {
  const _ProblemBankTreeNodeMeta._({
    required this.kind,
    this.school = '',
    this.year = '',
    this.document,
    this.big,
    this.mid,
    this.small,
    this.page,
  });

  factory _ProblemBankTreeNodeMeta.school(String school) {
    return _ProblemBankTreeNodeMeta._(
      kind: _ProblemBankTreeNodeKind.school,
      school: school,
    );
  }

  factory _ProblemBankTreeNodeMeta.year(String school, String year) {
    return _ProblemBankTreeNodeMeta._(
      kind: _ProblemBankTreeNodeKind.year,
      school: school,
      year: year,
    );
  }

  factory _ProblemBankTreeNodeMeta.document(
    LearningProblemDocumentSummary document,
  ) {
    return _ProblemBankTreeNodeMeta._(
      kind: _ProblemBankTreeNodeKind.document,
      document: document,
    );
  }

  factory _ProblemBankTreeNodeMeta.privateBig(
    ProblemBankPrivateMaterialBigNode big,
  ) {
    return _ProblemBankTreeNodeMeta._(
      kind: _ProblemBankTreeNodeKind.privateBig,
      big: big,
    );
  }

  factory _ProblemBankTreeNodeMeta.privateMid(
    ProblemBankPrivateMaterialMidNode mid,
  ) {
    return _ProblemBankTreeNodeMeta._(
      kind: _ProblemBankTreeNodeKind.privateMid,
      mid: mid,
    );
  }

  factory _ProblemBankTreeNodeMeta.privateSmall(
    ProblemBankPrivateMaterialSmallNode small,
  ) {
    return _ProblemBankTreeNodeMeta._(
      kind: _ProblemBankTreeNodeKind.privateSmall,
      small: small,
    );
  }

  factory _ProblemBankTreeNodeMeta.privatePage(
    ProblemBankPrivateMaterialPageNode page,
  ) {
    return _ProblemBankTreeNodeMeta._(
      kind: _ProblemBankTreeNodeKind.privatePage,
      page: page,
    );
  }

  final _ProblemBankTreeNodeKind kind;
  final String school;
  final String year;
  final LearningProblemDocumentSummary? document;
  final ProblemBankPrivateMaterialBigNode? big;
  final ProblemBankPrivateMaterialMidNode? mid;
  final ProblemBankPrivateMaterialSmallNode? small;
  final ProblemBankPrivateMaterialPageNode? page;
}

class ProblemBankPrivateMaterialBigNode {
  const ProblemBankPrivateMaterialBigNode({
    required this.title,
    required this.order,
    required this.mids,
  });

  final String title;
  final int order;
  final List<ProblemBankPrivateMaterialMidNode> mids;
}

class ProblemBankPrivateMaterialMidNode {
  const ProblemBankPrivateMaterialMidNode({
    required this.title,
    required this.order,
    required this.smalls,
  });

  final String title;
  final int order;
  final List<ProblemBankPrivateMaterialSmallNode> smalls;
}

class ProblemBankPrivateMaterialSmallNode {
  const ProblemBankPrivateMaterialSmallNode({
    required this.key,
    required this.title,
    required this.order,
    required this.subKey,
    required this.pages,
    required this.typeGroups,
    required this.questionUids,
  });

  final String key;
  final String title;
  final int order;
  final String subKey;
  final List<ProblemBankPrivateMaterialPageNode> pages;
  final List<ProblemBankPrivateMaterialTypeNode> typeGroups;
  final List<String> questionUids;

  int get questionCount => questionUids.length;
}

class ProblemBankPrivateMaterialTypeNode {
  const ProblemBankPrivateMaterialTypeNode({
    required this.key,
    required this.order,
    required this.label,
    required this.title,
    required this.questionUids,
  });

  final String key;
  final int order;
  final String label;
  final String title;
  final List<String> questionUids;

  int get questionCount => questionUids.length;
}

class ProblemBankPrivateMaterialPageNode {
  const ProblemBankPrivateMaterialPageNode({
    required this.key,
    required this.displayPage,
    required this.rawPage,
    required this.questionUids,
  });

  final String key;
  final int displayPage;
  final int rawPage;
  final List<String> questionUids;

  int get questionCount => questionUids.length;
}
