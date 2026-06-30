import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../app_overlays.dart';
import '../../services/textbook_explorer_service.dart';
import '../../services/textbook_pdf_service.dart';
import '../../widgets/app_snackbar.dart';
import '../../widgets/shared_folder_tree.dart';
import '../../widgets/solid_capsule_action_bar.dart';
import '../design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';

enum TbExRightMode { questions, pdf }

/// 교재 단원/문항 탐색 상태. 자원 화면(좌측 트리 패널 / 우측 콘텐츠)에서
/// 공유한다.
class TextbookExplorerController extends ChangeNotifier {
  TextbookExplorerController({
    required this.academyId,
    required this.bookId,
    required this.gradeLabel,
    required this.bookTitle,
    this.description,
    this.categoryLabel,
    this.folderLabel,
    this.onClose,
  });

  final String academyId;
  final String bookId;
  final String gradeLabel;
  final String bookTitle;
  final String? description;
  final String? categoryLabel;
  final String? folderLabel;
  VoidCallback? onClose;

  bool loading = true;
  String? error;
  TbExData data = TbExData.empty;

  bool basicInfoExpanded = false;
  TbExRightMode mode = TbExRightMode.questions;

  final Set<String> expandedNodeIds = <String>{};

  /// 이전 구현 호환용. 실제 필터 기준은 문제은행 사설교재 트리와 동일하게
  /// [checkedPageKeys] 하나로 관리한다.
  final Set<String> checkedSmallKeys = <String>{};

  /// 체크된 페이지 키 '${smallKey}#${rawPage}'.
  final Set<String> checkedPageKeys = <String>{};

  /// 하이라이트(선택)된 문항 selKey. 카드/PDF 크롭 탭으로 토글.
  final Set<String> selectedKeys = <String>{};

  /// 장바구니(문제은행 핸드오프 대상) selKey, 추가 순서 유지.
  final List<String> cartKeys = <String>[];

  /// selKey -> 문항 조회용.
  final Map<String, TbExItem> _itemBySelKey = <String, TbExItem>{};

  // PDF
  final PdfViewerController pdfController = PdfViewerController();
  TextbookPdfSource? pdfSource;
  Object? pdfError;
  bool pdfLoading = false;
  bool _pdfRequested = false;

  Map<int, List<TbExItem>> get itemsByPage => data.itemsByPage;

  Future<void> load() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      final loaded = await TextbookExplorerService.instance.load(
        bookId: bookId,
        gradeLabel: gradeLabel,
      );
      data = loaded;
      _itemBySelKey.clear();
      for (final big in loaded.units) {
        for (final mid in big.mids) {
          for (final small in mid.smalls) {
            for (final item in small.items) {
              _itemBySelKey[item.selKey] = item;
            }
          }
        }
      }
      loading = false;
      if (!loaded.hasQuestions) {
        error = '이 교재에는 연결된 문항 정보가 없어 단원/문항 탐색을 지원하지 않습니다.';
      }
    } catch (e) {
      loading = false;
      error = '교재 데이터를 불러오지 못했습니다.\n$e';
    }
    notifyListeners();
  }

  // PdfViewerController(pdfrx)는 별도 dispose가 필요 없다.

  void toggleBasicInfo() {
    basicInfoExpanded = !basicInfoExpanded;
    notifyListeners();
  }

  void toggleExpand(String nodeId) {
    if (!expandedNodeIds.remove(nodeId)) expandedNodeIds.add(nodeId);
    notifyListeners();
  }

  bool isSmallFullyChecked(TbExSmallUnit small) {
    final pageKeys = small.pages.map((p) => '${small.key}#${p.rawPage}');
    return small.pages.isNotEmpty && pageKeys.every(checkedPageKeys.contains);
  }

  bool isSmallPartiallyChecked(TbExSmallUnit small) {
    if (isSmallFullyChecked(small)) return false;
    return small.pages
        .any((p) => checkedPageKeys.contains('${small.key}#${p.rawPage}'));
  }

  bool isPageChecked(String smallKey, int rawPage) {
    return checkedPageKeys.contains('$smallKey#$rawPage');
  }

  void toggleSmall(TbExSmallUnit small) {
    final pageKeys =
        small.pages.map((p) => '${small.key}#${p.rawPage}').toList();
    final allSelected =
        pageKeys.isNotEmpty && pageKeys.every(checkedPageKeys.contains);
    for (final key in pageKeys) {
      if (allSelected) {
        checkedPageKeys.remove(key);
      } else {
        checkedPageKeys.add(key);
      }
    }
    checkedSmallKeys.clear();
    notifyListeners();
  }

  void togglePageKeys(Iterable<String> pageKeys, bool selected) {
    for (final key in pageKeys) {
      if (selected) {
        checkedPageKeys.add(key);
      } else {
        checkedPageKeys.remove(key);
      }
    }
    checkedSmallKeys.clear();
    notifyListeners();
  }

  void togglePage(TbExSmallUnit small, TbExPage page) {
    final pageKey = '${small.key}#${page.rawPage}';
    if (checkedPageKeys.contains(pageKey)) {
      checkedPageKeys.remove(pageKey);
    } else {
      checkedPageKeys.add(pageKey);
    }
    checkedSmallKeys.clear();
    notifyListeners();
  }

  bool pageDragActive = false;
  bool pageDragSelectMode = true;
  Set<String> pageDragBaseKeys = <String>{};
  final Set<String> pageDragKeys = <String>{};

  bool isPageEffectivelyChecked(String smallKey, int rawPage) {
    final pageKey = '$smallKey#$rawPage';
    if (!pageDragActive) return checkedPageKeys.contains(pageKey);
    if (pageDragKeys.contains(pageKey)) return pageDragSelectMode;
    return pageDragBaseKeys.contains(pageKey);
  }

  void startPageDrag(String pageKey) {
    final selected = checkedPageKeys.contains(pageKey);
    pageDragActive = true;
    pageDragSelectMode = !selected;
    pageDragBaseKeys = Set<String>.from(checkedPageKeys);
    pageDragKeys
      ..clear()
      ..add(pageKey);
    notifyListeners();
  }

  void enterPageDrag(String pageKey) {
    if (!pageDragActive) return;
    if (pageDragKeys.contains(pageKey)) return;
    pageDragKeys.add(pageKey);
    notifyListeners();
  }

  void finishPageDrag() {
    if (!pageDragActive) return;
    final keys = List<String>.from(pageDragKeys);
    final selected = pageDragSelectMode;
    pageDragActive = false;
    pageDragKeys.clear();
    pageDragBaseKeys = <String>{};
    if (keys.isNotEmpty) {
      togglePageKeys(keys, selected);
    } else {
      notifyListeners();
    }
  }

  void cancelPageDrag() {
    if (!pageDragActive) return;
    pageDragActive = false;
    pageDragKeys.clear();
    pageDragBaseKeys = <String>{};
    notifyListeners();
  }

  bool itemDragActive = false;
  bool itemDragSelectMode = true;
  bool itemDragSuppressNextTap = false;
  Set<String> itemDragBaseKeys = <String>{};
  final Set<String> itemDragKeys = <String>{};

  bool isItemEffectivelySelected(String selKey) {
    if (!itemDragActive) return selectedKeys.contains(selKey);
    if (itemDragKeys.contains(selKey)) return itemDragSelectMode;
    return itemDragBaseKeys.contains(selKey);
  }

  void startItemDrag(String selKey) {
    final selected = selectedKeys.contains(selKey);
    itemDragActive = true;
    itemDragSelectMode = !selected;
    itemDragBaseKeys = Set<String>.from(selectedKeys);
    itemDragKeys
      ..clear()
      ..add(selKey);
    notifyListeners();
  }

  void enterItemDrag(String selKey) {
    if (!itemDragActive) return;
    if (itemDragKeys.contains(selKey)) return;
    itemDragKeys.add(selKey);
    notifyListeners();
  }

  void finishItemDrag() {
    if (!itemDragActive) return;
    final keys = List<String>.from(itemDragKeys);
    final selected = itemDragSelectMode;
    itemDragActive = false;
    itemDragKeys.clear();
    itemDragBaseKeys = <String>{};
    if (keys.isNotEmpty) {
      toggleSelectKeys(keys, selected);
      itemDragSuppressNextTap = true;
    } else {
      notifyListeners();
    }
  }

  void cancelItemDrag() {
    if (!itemDragActive) return;
    itemDragActive = false;
    itemDragKeys.clear();
    itemDragBaseKeys = <String>{};
    notifyListeners();
  }

  /// 체크 상태에 따른 표시 대상 문항(번호 있는 것만).
  List<TbExItem> get visibleItems {
    final out = <TbExItem>[];
    final seen = <String>{};
    void addItem(TbExItem item) {
      if (item.isSetHeader) return;
      if (item.problemNumber.trim().isEmpty) return;
      if (!seen.add(item.selKey)) return;
      out.add(item);
    }

    for (final big in data.units) {
      for (final mid in big.mids) {
        for (final small in mid.smalls) {
          for (final page in small.pages) {
            final pageChecked =
                checkedPageKeys.contains('${small.key}#${page.rawPage}');
            if (pageChecked) {
              for (final item in page.items) {
                addItem(item);
              }
            }
          }
        }
      }
    }
    return out;
  }

  bool get hasSelectionFilter => checkedPageKeys.isNotEmpty;

  /// 우측 상단 FAB 타이틀. 선택 범위가 한 소단원 안이면 소단원명,
  /// 여러 소단원이면 가능한 가장 가까운 공통 중단원/대단원명으로 축약한다.
  String get currentScopeTitle {
    if (checkedPageKeys.isEmpty) return '범위 선택';
    TbExBigUnit? matchedBig;
    TbExMidUnit? matchedMid;
    TbExSmallUnit? matchedSmall;
    var bigCount = 0;
    var midCount = 0;
    var smallCount = 0;
    for (final big in data.units) {
      var bigHasSelection = false;
      for (final mid in big.mids) {
        var midHasSelection = false;
        for (final small in mid.smalls) {
          final smallHasSelection = small.pages.any(
            (p) => checkedPageKeys.contains('${small.key}#${p.rawPage}'),
          );
          if (!smallHasSelection) continue;
          matchedSmall = small;
          smallCount += 1;
          midHasSelection = true;
          bigHasSelection = true;
        }
        if (midHasSelection) {
          matchedMid = mid;
          midCount += 1;
        }
      }
      if (bigHasSelection) {
        matchedBig = big;
        bigCount += 1;
      }
    }
    if (smallCount == 1 && matchedSmall != null) return matchedSmall.name;
    if (midCount == 1 && matchedMid != null) return matchedMid.name;
    if (bigCount == 1 && matchedBig != null) return matchedBig.name;
    final title = bookTitle.trim();
    return title.isEmpty ? '선택 범위' : title;
  }

  String get currentScopeCountLabel {
    final count = visibleItems.length;
    return count <= 0 ? '' : '$count문항';
  }

  void toggleSelectKey(String selKey) {
    if (itemDragSuppressNextTap) {
      itemDragSuppressNextTap = false;
      notifyListeners();
      return;
    }
    if (!selectedKeys.remove(selKey)) selectedKeys.add(selKey);
    notifyListeners();
  }

  void toggleSelectKeys(Iterable<String> keys, bool selected) {
    for (final key in keys) {
      if (selected) {
        selectedKeys.add(key);
      } else {
        selectedKeys.remove(key);
      }
    }
    notifyListeners();
  }

  void toggleTypeGroupSelection(List<TbExItem> items) {
    if (items.isEmpty) return;
    final keys = items.map((item) => item.selKey).toList();
    final allSelected = keys.every(selectedKeys.contains);
    for (final key in keys) {
      if (allSelected) {
        selectedKeys.remove(key);
      } else {
        selectedKeys.add(key);
      }
    }
    notifyListeners();
  }

  bool isSelected(String selKey) => selectedKeys.contains(selKey);

  int get cartCount => cartKeys.length;

  void addSelectedToCart(BuildContext context) {
    if (selectedKeys.isEmpty) {
      showAppSnackBar(context, '먼저 문항을 선택하세요.');
      return;
    }
    var added = 0;
    for (final key in selectedKeys) {
      if (cartKeys.contains(key)) continue;
      cartKeys.add(key);
      added += 1;
    }
    notifyListeners();
    showAppSnackBar(
      context,
      added > 0 ? '장바구니에 $added개 담았습니다.' : '이미 담긴 문항입니다.',
    );
  }

  void openCart(BuildContext context) {
    final uids = <String>[];
    for (final key in cartKeys) {
      final item = _itemBySelKey[key];
      if (item != null && item.hasUid) uids.add(item.questionUid);
    }
    if (uids.isEmpty) {
      showAppSnackBar(context, '장바구니에 담긴(식별 가능한) 문항이 없습니다.');
      return;
    }
    requestOpenQuestionsInProblemBank(uids);
    onClose?.call();
  }

  void switchMode(TbExRightMode next) {
    if (mode == next) return;
    mode = next;
    notifyListeners();
    if (next == TbExRightMode.pdf) ensurePdfLoaded();
  }

  Future<void> ensurePdfLoaded() async {
    if (_pdfRequested) return;
    _pdfRequested = true;
    pdfLoading = true;
    notifyListeners();
    try {
      final source = await TextbookPdfService.instance.resolve(
        TextbookPdfRef(
          academyId: academyId,
          fileId: bookId,
          gradeLabel: gradeLabel,
          kind: 'body',
          displayName: bookTitle,
        ),
      );
      pdfSource = source;
      pdfLoading = false;
    } catch (e) {
      pdfError = e;
      pdfLoading = false;
    }
    notifyListeners();
  }
}

// ============================================================ LEFT PANEL
class _NodeTag {
  const _NodeTag.big()
      : kind = 'big',
        small = null,
        page = null;
  const _NodeTag.mid()
      : kind = 'mid',
        small = null,
        page = null;
  const _NodeTag.small(this.small)
      : kind = 'small',
        page = null;
  const _NodeTag.page(this.small, this.page) : kind = 'page';

  final String kind;
  final TbExSmallUnit? small;
  final TbExPage? page;
}

/// 좌측 단원 트리 패널 — 자원 화면 폴더 트리 자리에 그려진다.
/// 상단 타이틀에 책 제목 + 정보/뒤로가기 버튼을 둔다.
class TextbookExplorerTreePanel extends StatelessWidget {
  const TextbookExplorerTreePanel({super.key, required this.controller});

  final TextbookExplorerController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final brightness = Theme.of(context).brightness;
        final style = FabTabBarTokens.previewAcademyPanelStyleFor(brightness);
        return Listener(
          onPointerUp: (_) => controller.finishPageDrag(),
          onPointerCancel: (_) => controller.cancelPageDrag(),
          child: SharedFolderTreePanel(
            title: controller.bookTitle.trim().isEmpty
                ? '(이름 없음)'
                : controller.bookTitle.trim(),
            subtitle: _subtitle(),
            reserveSubtitleSlot: true,
            titleTrailing: _buildTitleTrailing(context, style),
            reserveTitleTrailingSlot: true,
            titleTrailingSlotFraction: 0.32,
            isLoading: controller.loading,
            emptyMessage: '단원 정보가 없습니다.',
            nodes: _buildNodes(),
            selectedNodeId: null,
            expandedNodeIds: controller.expandedNodeIds,
            onNodeTap: (node) => _onNodeTap(node),
            onToggleExpanded: (node) => controller.toggleExpand(node.id),
            wrapNodeRow: (context, node, depth, row) =>
                _wrapRow(context, style, node, depth, row),
          ),
        );
      },
    );
  }

  String? _subtitle() {
    if (controller.loading) return null;
    if (!controller.basicInfoExpanded) {
      final desc = (controller.description ?? '').trim();
      return desc.isEmpty ? '정보 보기' : desc;
    }
    final parts = <String>[
      if ((controller.categoryLabel ?? '').trim().isNotEmpty)
        '분류 ${controller.categoryLabel!.trim()}',
      if ((controller.folderLabel ?? '').trim().isNotEmpty)
        '폴더 ${controller.folderLabel!.trim()}'
      else
        '폴더 루트',
      if (controller.data.totalPages > 0) '총 ${controller.data.totalPages}쪽',
      '총 ${controller.data.totalQuestions}문항',
    ];
    return parts.join(' · ');
  }

  Widget _buildTitleTrailing(
    BuildContext context,
    PreviewAcademyPanelStyle style,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        _MiniIconButton(
          icon: controller.basicInfoExpanded
              ? Icons.expand_less_rounded
              : Icons.info_outline,
          tooltip: '교재 정보',
          color: style.icon,
          onTap: controller.toggleBasicInfo,
        ),
      ],
    );
  }

  List<SharedFolderTreeNode> _buildNodes() {
    final out = <SharedFolderTreeNode>[];
    for (final big in controller.data.units) {
      final bigId = 'big:${big.order}:${big.name}';
      final midNodes = <SharedFolderTreeNode>[];
      for (final mid in big.mids) {
        final midId = '$bigId/mid:${mid.order}:${mid.name}';
        final smallNodes = <SharedFolderTreeNode>[];
        for (final small in mid.smalls) {
          final pageNodes = <SharedFolderTreeNode>[
            for (final page in small.pages)
              SharedFolderTreeNode(
                id: 'page:${small.key}#${page.rawPage}',
                label: '${page.displayPage ?? page.rawPage}쪽 · '
                    '${page.numberedQuestionCount}문항',
                icon: Icons.description_outlined,
                selectedIcon: Icons.check_circle_outline,
                data: _NodeTag.page(small, page),
              ),
          ];
          smallNodes.add(
            SharedFolderTreeNode(
              id: 'small:${small.key}',
              label: small.name,
              icon: Icons.folder_outlined,
              selectedIcon: Icons.folder,
              data: _NodeTag.small(small),
              children: pageNodes,
            ),
          );
        }
        midNodes.add(
          SharedFolderTreeNode(
            id: midId,
            label: mid.name,
            icon: Icons.folder_outlined,
            data: const _NodeTag.mid(),
            children: smallNodes,
          ),
        );
      }
      out.add(
        SharedFolderTreeNode(
          id: bigId,
          label: big.name,
          rowStyle: SharedFolderTreeRowStyle.section,
          data: const _NodeTag.big(),
          children: midNodes,
        ),
      );
    }
    return out;
  }

  void _onNodeTap(SharedFolderTreeNode node) {
    if (node.children.isNotEmpty) {
      controller.toggleExpand(node.id);
    }
  }

  Widget _wrapRow(
    BuildContext context,
    PreviewAcademyPanelStyle style,
    SharedFolderTreeNode node,
    int depth,
    Widget row,
  ) {
    final tag = node.data;
    if (tag is! _NodeTag) return row;
    if (tag.kind == 'small' && tag.small != null) {
      return _buildSmallTreeRow(context, style, node, depth, tag.small!);
    }
    if (tag.kind == 'page' && tag.small != null && tag.page != null) {
      return _buildPageTreeRow(
        context,
        style,
        depth,
        tag.small!,
        tag.page!,
      );
    }
    return row;
  }

  double _treeRowOuterPaddingLeft(int depth) {
    return FabTabBarTokens.previewAcademyGroupedRowPaddingHorizontal -
        18 +
        depth * 10.0;
  }

  Widget _buildSmallTreeRow(
    BuildContext context,
    PreviewAcademyPanelStyle style,
    SharedFolderTreeNode node,
    int depth,
    TbExSmallUnit small,
  ) {
    const active = Color(0xFF33A373);
    final pageKeys =
        small.pages.map((page) => '${small.key}#${page.rawPage}').toList();
    final selected = pageKeys.isNotEmpty &&
        pageKeys.every(controller.checkedPageKeys.contains);
    final partiallySelected =
        !selected && pageKeys.any(controller.checkedPageKeys.contains);
    final hasChildren = node.children.isNotEmpty;
    final isExpanded = controller.expandedNodeIds.contains(node.id);

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
          onTap: hasChildren ? () => controller.toggleExpand(node.id) : null,
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
                    onTap: () => controller.toggleExpand(node.id),
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(
                        isExpanded ? Icons.expand_more : Icons.chevron_right,
                        size: 16,
                        color: style.icon,
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
                  side: BorderSide(color: style.border),
                  activeColor: active,
                  onChanged: (value) =>
                      controller.togglePageKeys(pageKeys, value == true),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    small.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? style.title : style.hint,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                      fontSize: FabTabBarTokens.fabBarLabelFontSize,
                      letterSpacing: -0.1,
                    ),
                  ),
                ),
                Text(
                  '${small.pages.length}쪽',
                  style: TextStyle(
                    color: style.label,
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

  Widget _buildPageTreeRow(
    BuildContext context,
    PreviewAcademyPanelStyle style,
    int depth,
    TbExSmallUnit small,
    TbExPage page,
  ) {
    const active = Color(0xFF33A373);
    final brightness = Theme.of(context).brightness;
    final pageKey = '${small.key}#${page.rawPage}';
    final selected =
        controller.isPageEffectivelyChecked(small.key, page.rawPage);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        _treeRowOuterPaddingLeft(depth),
        0,
        12,
        sharedFolderTreeItemSpacing,
      ),
      child: MouseRegion(
        onEnter: (_) => controller.enterPageDrag(pageKey),
        child: Listener(
          onPointerDown: (event) {
            if (event.buttons == kPrimaryMouseButton) {
              controller.startPageDrag(pageKey);
            }
          },
          child: Material(
            color: Colors.transparent,
            child: Ink(
              decoration: BoxDecoration(
                color: selected
                    ? FabTabBarTokens.fabHighlightPillFill(brightness)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: sharedFolderTreeNavRowPaddingVertical,
                ),
                child: Row(
                  children: [
                    const SizedBox(width: sharedFolderTreeLeadingWidth),
                    const SizedBox(width: 2),
                    Checkbox(
                      value: selected,
                      visualDensity: VisualDensity.compact,
                      side: BorderSide(color: style.border),
                      activeColor: active,
                      onChanged: (_) => controller.togglePage(small, page),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '${page.displayPage ?? page.rawPage}쪽',
                        style: TextStyle(
                          color: selected ? style.title : style.hint,
                          fontWeight:
                              selected ? FontWeight.w800 : FontWeight.w600,
                          fontSize: FabTabBarTokens.fabBarLabelFontSize,
                          letterSpacing: -0.1,
                        ),
                      ),
                    ),
                    Text(
                      '${page.numberedQuestionCount}문항',
                      style: TextStyle(
                        color: style.label,
                        fontWeight: FontWeight.w700,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// [SolidCapsuleActionBar]와 동일 토큰의 원형 단일 아이콘 버튼.
class _SolidCircleActionButton extends StatelessWidget {
  const _SolidCircleActionButton({
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.iconSize = FabTabBarTokens.previewAcademyBaseFontSize + 8,
    this.size = FabTabBarTokens.fabBarHeight,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double iconSize;
  final double size;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final fg = SolidCapsuleActionBarTokens.iconColor(brightness);

    final button = Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, size: iconSize, color: fg),
        ),
      ),
    );

    final child = tooltip == null || tooltip!.isEmpty
        ? button
        : Tooltip(message: tooltip, child: button);

    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: SolidCapsuleActionBarTokens.boxShadows(brightness),
      ),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: SolidCapsuleActionBarTokens.background(brightness),
          border:
              Border.all(color: SolidCapsuleActionBarTokens.border(brightness)),
        ),
        child: child,
      ),
    );
  }
}

class _MiniIconButton extends StatelessWidget {
  const _MiniIconButton({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 28,
            height: 28,
            child: Icon(icon, size: 18, color: color),
          ),
        ),
      ),
    );
  }
}

// =========================================================== RIGHT CONTENT

/// 교재·시험 카드 그리드와 동일한 상단 타이틀 밴드 높이.
const double _tbExScrollTopPadding =
    (FabTabBarTokens.previewAcademyTopInset - 12) +
    FabTabBarTokens.previewAcademyMainTitleFontSize * 1.15 +
    12;

/// 우측 문항 리스트·헤더 좌측 기준선(유형 체크박스 열).
const double _tbExContentHorizontalInset = 4.0;
const double _tbExTypeCheckboxColumnWidth = 18.0;
const double _tbExTypeCheckboxGap = 2.0;
const double _tbExTypeLabelInset = _tbExContentHorizontalInset +
    _tbExTypeCheckboxColumnWidth +
    _tbExTypeCheckboxGap;
const double _tbExQuestionCardExtraInset = 4.0;

class TextbookExplorerContent extends StatelessWidget {
  const TextbookExplorerContent({super.key, required this.controller});

  final TextbookExplorerController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final brightness = Theme.of(context).brightness;
        final style = FabTabBarTokens.previewAcademyPanelStyleFor(brightness);
        return Stack(
          children: [
            Positioned.fill(
              child: _buildBody(context, style),
            ),
            Positioned(
              top: FabTabBarTokens.previewAcademyTopInset - 12,
              left: _tbExContentHorizontalInset,
              right: 12,
              child: _buildHeader(context, style),
            ),
          ],
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, PreviewAcademyPanelStyle style) {
    return Row(
      children: [
        _SolidCircleActionButton(
          icon: Icons.arrow_back_rounded,
          tooltip: '교재 목록으로 돌아가기',
          size: FabTabBarTokens.fabBarHeight,
          iconSize: FabTabBarTokens.previewAcademyBaseFontSize + 8,
          onPressed: () => controller.onClose?.call(),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _ScopeTitleText(
            title: controller.currentScopeTitle,
            style: style,
          ),
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context, PreviewAcademyPanelStyle style) {
    if (controller.loading) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
      );
    }
    if (controller.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(
            controller.error!,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: style.hint,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          ),
        ),
      );
    }
    if (controller.mode == TbExRightMode.pdf) {
      return _buildPdf(context, style);
    }
    return _buildQuestions(context, style);
  }

  Widget _buildQuestions(BuildContext context, PreviewAcademyPanelStyle style) {
    if (!controller.hasSelectionFilter) {
      return Center(
        child: Text(
          '왼쪽 단원 트리에서 소단원 또는 페이지를 체크하세요.',
          style: TextStyle(color: style.hint, fontSize: 14),
        ),
      );
    }
    final items = controller.visibleItems;
    if (items.isEmpty) {
      return Center(
        child: Text(
          '선택한 범위에 표시할 문항이 없습니다.',
          style: TextStyle(color: style.hint, fontSize: 14),
        ),
      );
    }
    final grouped = <String, List<TbExItem>>{};
    for (final item in items) {
      grouped.putIfAbsent(item.typeGroupKey, () => <TbExItem>[]).add(item);
    }
    final keys = grouped.keys.toList(growable: false);
    return Listener(
      onPointerUp: (_) => controller.finishItemDrag(),
      onPointerCancel: (_) => controller.cancelItemDrag(),
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(
          _tbExContentHorizontalInset,
          _tbExScrollTopPadding,
          4,
          120,
        ),
        itemCount: keys.length,
        itemBuilder: (context, index) {
          final key = keys[index];
          final groupItems = grouped[key] ?? const <TbExItem>[];
          return Padding(
            padding: EdgeInsets.only(bottom: index == keys.length - 1 ? 0 : 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildTypeHeader(style, key, groupItems),
                const SizedBox(height: 10),
                Padding(
                  padding: EdgeInsets.only(
                    left: _tbExTypeLabelInset -
                        _tbExContentHorizontalInset +
                        _tbExQuestionCardExtraInset,
                  ),
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final item in groupItems)
                        MouseRegion(
                          onEnter: (_) =>
                              controller.enterItemDrag(item.selKey),
                          child: Listener(
                            onPointerDown: (event) {
                              if (event.buttons == kPrimaryMouseButton) {
                                controller.startItemDrag(item.selKey);
                              }
                            },
                            child: _QuestionCard(
                              item: item,
                              selected: controller
                                  .isItemEffectivelySelected(item.selKey),
                              style: style,
                              onTap: () =>
                                  controller.toggleSelectKey(item.selKey),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildTypeHeader(
    PreviewAcademyPanelStyle style,
    String key,
    List<TbExItem> groupItems,
  ) {
    const active = Color(0xFF33A373);
    final allSelected = groupItems.isNotEmpty &&
        groupItems.every((item) => controller.isSelected(item.selKey));
    final anySelected =
        groupItems.any((item) => controller.isSelected(item.selKey));

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Checkbox(
                value: allSelected ? true : (anySelected ? null : false),
                tristate: true,
                visualDensity: VisualDensity.compact,
                side: BorderSide(color: style.border),
                activeColor: active,
                onChanged: (_) =>
                    controller.toggleTypeGroupSelection(groupItems),
              ),
              const SizedBox(width: 2),
              Expanded(
                child: Text(
                  TbExItem.typeGroupTitleOf(key),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: style.title,
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${groupItems.length}문항',
                style: TextStyle(
                  color: style.hint,
                  fontWeight: FontWeight.w800,
                  fontSize: 12.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Divider(height: 1, thickness: 1, color: style.divider),
        ],
      ),
    );
  }

  Widget _buildPdf(BuildContext context, PreviewAcademyPanelStyle style) {
    if (controller.pdfLoading) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
      );
    }
    if (controller.pdfError != null) {
      return Center(
        child: Text(
          '원본 PDF를 열 수 없습니다.\n${controller.pdfError}',
          textAlign: TextAlign.center,
          style: TextStyle(color: style.hint, fontSize: 13.5),
        ),
      );
    }
    final source = controller.pdfSource;
    if (source == null) {
      return Center(
        child: Text(
          '원본 PDF를 준비 중입니다.',
          style: TextStyle(color: style.hint, fontSize: 13.5),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: _tbExScrollTopPadding),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(
          FabTabBarTokens.previewAcademyGroupedCardRadius,
        ),
        child: _PdfViewer(controller: controller),
      ),
    );
  }
}

class _ScopeTitleText extends StatelessWidget {
  const _ScopeTitleText({
    required this.title,
    required this.style,
  });

  final String title;
  final PreviewAcademyPanelStyle style;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: FabTabBarTokens.previewAcademyMainTitleStyle(style),
      ),
    );
  }
}

// =============================================================== PDF VIEWER
class _PdfViewer extends StatelessWidget {
  const _PdfViewer({required this.controller});

  final TextbookExplorerController controller;

  PdfPageLayout _layout(List<PdfPage> pages, PdfViewerParams params) {
    var maxWidth = 0.0;
    for (final p in pages) {
      if (p.width > maxWidth) maxWidth = p.width;
    }
    final width = maxWidth + params.margin * 2;
    const pageGap = 18.0;
    var y = params.margin;
    final layouts = <Rect>[];
    for (final p in pages) {
      final x = (width - p.width) / 2.0;
      layouts.add(Rect.fromLTWH(x, y, p.width, p.height));
      y += p.height + pageGap;
    }
    return PdfPageLayout(
      pageLayouts: layouts,
      documentSize: Size(width, y + params.margin),
    );
  }

  PdfViewerParams _params() {
    return PdfViewerParams(
      margin: 8,
      layoutPages: _layout,
      pageAnchor: PdfPageAnchor.top,
      maxScale: 8,
      minScale: 0.1,
      calculateInitialZoom: (document, ctrl, fitZoom, coverZoom) => fitZoom,
      pageOverlaysBuilder: (context, pageRect, page) {
        final items = controller.itemsByPage[page.pageNumber];
        if (items == null || items.isEmpty) return const <Widget>[];
        final w = pageRect.width;
        final h = pageRect.height;
        return [
          for (final item in items)
            if (item.hasRegion)
              _PdfRegionOverlay(
                left: w * item.xmin,
                top: h * item.ymin,
                width: w * (item.xmax - item.xmin),
                height: h * (item.ymax - item.ymin),
                label: item.displayNumber,
                selected: controller.isSelected(item.selKey),
                onTap: () => controller.toggleSelectKey(item.selKey),
              ),
        ];
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final source = controller.pdfSource!;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        switch (source.type) {
          case TextbookPdfSourceType.localFile:
            final path = source.localPath ?? '';
            if (path.isEmpty) return const SizedBox.shrink();
            return PdfViewer.file(
              path,
              controller: controller.pdfController,
              params: _params(),
            );
          case TextbookPdfSourceType.legacyUrl:
          case TextbookPdfSourceType.remoteUrl:
            final uri = Uri.tryParse(source.url ?? '');
            if (uri == null) return const SizedBox.shrink();
            return PdfViewer.uri(
              uri,
              controller: controller.pdfController,
              params: _params(),
            );
        }
      },
    );
  }
}

class _PdfRegionOverlay extends StatelessWidget {
  const _PdfRegionOverlay({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final double left;
  final double top;
  final double width;
  final double height;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final border = selected ? const Color(0xFF33A373) : const Color(0x667AA9E6);
    final fill = selected ? const Color(0x3333A373) : Colors.transparent;
    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: fill,
            border: Border.all(color: border, width: selected ? 2 : 1),
            borderRadius: BorderRadius.circular(4),
          ),
          padding: const EdgeInsets.only(left: 4, top: 2),
          alignment: Alignment.topLeft,
          child: Text(
            label,
            style: TextStyle(
              color:
                  selected ? const Color(0xFF14361F) : const Color(0xCC7AA9E6),
              fontSize: 10,
              fontWeight: FontWeight.w800,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================ QUESTION CARD
class _QuestionCard extends StatelessWidget {
  const _QuestionCard({
    required this.item,
    required this.selected,
    required this.style,
    required this.onTap,
  });

  final TbExItem item;
  final bool selected;
  final PreviewAcademyPanelStyle style;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF33A373);
    final brightness = Theme.of(context).brightness;
    final cardBg = selected
        ? accent.withValues(alpha: brightness == Brightness.dark ? 0.18 : 0.10)
        : style.dropdownBackground;
    return SizedBox(
      width: 118,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                height: 58,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: selected ? accent : style.border,
                    width: selected ? 2 : 1,
                  ),
                ),
                child: Text(
                  item.displayNumber,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: style.title,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (item.difficultyLabel.trim().isNotEmpty) ...[
                    _DiffDot(label: item.difficultyLabel),
                    const SizedBox(width: 5),
                  ],
                  if (item.answerKind.label.isNotEmpty)
                    Text(
                      item.answerKind.label,
                      style: TextStyle(
                        color: style.hint,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DiffDot extends StatelessWidget {
  const _DiffDot({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = _colorsFor(label);
    final display = _displayLabel(label);
    return Tooltip(
      message: '난이도 $label',
      child: Container(
        width: 16,
        height: 16,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: colors.$1,
          border: Border.all(color: colors.$2),
        ),
        child: Text(
          display,
          maxLines: 1,
          style: TextStyle(
            color: colors.$3,
            fontSize: display.length >= 2 ? 7.5 : 9,
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

  static (Color, Color, Color) _colorsFor(String label) {
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
      return (
        const Color(0xFF21362D),
        const Color(0xFF547B62),
        const Color(0xFFC3DEC8),
      );
    }
    if (isHard) {
      return (
        const Color(0xFF3A2C2A),
        const Color(0xFF7C5C55),
        const Color(0xFFE1C6BE),
      );
    }
    return (
      const Color(0xFF24323A),
      const Color(0xFF516B7A),
      const Color(0xFFC4D5DE),
    );
  }
}

// ================================================================= FAB BAR
class TbExFabBar extends StatelessWidget {
  const TbExFabBar({
    super.key,
    required this.mode,
    required this.cartCount,
    required this.selectedCount,
    required this.enabled,
    required this.onQuestionsMode,
    required this.onPdfMode,
    required this.onAdd,
    required this.onOpenCart,
  });

  final TbExRightMode mode;
  final int cartCount;
  final int selectedCount;
  final bool enabled;
  final VoidCallback onQuestionsMode;
  final VoidCallback onPdfMode;
  final VoidCallback onAdd;
  final VoidCallback onOpenCart;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final palette = FabTabBarTokens.paletteFor(brightness);
    final radius = BorderRadius.circular(FabTabBarTokens.fabBarHeight / 2);
    final disabled = !enabled;

    return Center(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: palette.boxShadows,
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: BackdropFilter(
            filter: ImageFilter.blur(
              sigmaX: FabTabBarTokens.fabRelatedBlurSigmaFor(brightness),
              sigmaY: FabTabBarTokens.fabRelatedBlurSigmaFor(brightness),
            ),
            child: Container(
              height: FabTabBarTokens.fabBarHeight,
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: radius,
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _FabPill(
                      icon: Icons.grid_view_rounded,
                      label: '문항별',
                      selected: mode == TbExRightMode.questions,
                      enabled: !disabled,
                      onTap: onQuestionsMode,
                    ),
                    _FabPill(
                      icon: Icons.picture_as_pdf_outlined,
                      label: '원본보기',
                      selected: mode == TbExRightMode.pdf,
                      enabled: !disabled,
                      onTap: onPdfMode,
                      width: 128,
                    ),
                    _FabPill(
                      icon: Icons.add_rounded,
                      label: selectedCount > 0 ? '추가 $selectedCount' : '추가',
                      selected: false,
                      enabled: !disabled,
                      onTap: onAdd,
                      width: selectedCount > 0 ? 128 : 112,
                    ),
                    _FabPill(
                      icon: Icons.shopping_cart_outlined,
                      label: cartCount > 0 ? '장바구니 $cartCount' : '장바구니',
                      selected: false,
                      enabled: !disabled && cartCount > 0,
                      onTap: onOpenCart,
                      width: 144,
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
}

class _FabPill extends StatelessWidget {
  const _FabPill({
    required this.icon,
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
    this.width = 112,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;
  final double width;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final palette = FabTabBarTokens.paletteFor(brightness);
    final bg = selected ? palette.highlight : Colors.transparent;
    final fg = !enabled
        ? palette.labelUnselected.withValues(alpha: 0.45)
        : (selected ? palette.labelSelected : palette.labelUnselected);

    return Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 450),
      child: SizedBox(
        width: width,
        height: double.infinity,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: enabled ? onTap : null,
              borderRadius: BorderRadius.circular(999),
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 20, color: fg),
                    const SizedBox(width: 7),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily:
                            FabTabBarTokens.previewAcademyLabelFontFamily,
                        color: fg,
                        fontSize: FabTabBarTokens.fabBarLabelFontSize,
                        fontWeight: FontWeight.w600,
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
}

/// 교재 탐색 액션 FAB — [FabStyleScreenTabBarOverlay]와 동일 루트 오버레이·Y 기준.
class TextbookExplorerFabOverlay {
  OverlayEntry? _entry;
  TextbookExplorerController? _controller;
  double _left = 0;
  double _right = 0;
  bool _syncScheduled = false;
  bool _disposed = false;

  void sync(
    BuildContext context, {
    TextbookExplorerController? controller,
    required double left,
    required double right,
  }) {
    if (_disposed) return;
    if (controller == null) {
      hide();
      return;
    }
    _controller = controller;
    _left = left;
    _right = right;

    if (_syncScheduled) return;
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      if (_disposed || !context.mounted) return;
      final overlay = Overlay.maybeOf(context, rootOverlay: true);
      if (overlay == null) return;

      if (_entry == null) {
        _entry = OverlayEntry(builder: _buildOverlay);
        overlay.insert(_entry!);
      } else {
        _entry!.markNeedsBuild();
      }
    });
  }

  void hide() {
    _controller = null;
    _entry?.remove();
    _entry = null;
  }

  void dispose() {
    _disposed = true;
    hide();
  }

  Widget _buildOverlay(BuildContext overlayContext) {
    final controller = _controller;
    if (controller == null) return const SizedBox.shrink();

    return Positioned(
      left: _left,
      right: _right,
      bottom: FabTabBarTokens.fabBarBottomInset,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          return TbExFabBar(
            mode: controller.mode,
            cartCount: controller.cartCount,
            selectedCount: controller.selectedKeys.length,
            enabled: !controller.loading && controller.data.hasQuestions,
            onQuestionsMode: () =>
                controller.switchMode(TbExRightMode.questions),
            onPdfMode: () => controller.switchMode(TbExRightMode.pdf),
            onAdd: () => controller.addSelectedToCart(overlayContext),
            onOpenCart: () => controller.openCart(overlayContext),
          );
        },
      ),
    );
  }
}
