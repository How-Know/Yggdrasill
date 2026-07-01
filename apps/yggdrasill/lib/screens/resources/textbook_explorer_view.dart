import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../app_overlays.dart';
import '../../services/learning_problem_bank_service.dart';
import '../../services/textbook_explorer_service.dart';
import '../../services/textbook_pdf_service.dart';
import '../../theme/ygg_semantic_colors.dart';
import '../../widgets/app_snackbar.dart';
import '../../widgets/shared_folder_tree.dart';
import '../../widgets/solid_capsule_action_bar.dart';
import '../design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';
import '../learning/models/problem_bank_export_models.dart';
import '../learning/widgets/problem_bank_bottom_fab_bar.dart';
import '../learning/widgets/problem_bank_export_options_fab.dart';
import '../learning/widgets/problem_bank_export_options_panel.dart';
import 'textbook_explorer_export_launcher.dart';

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

  /// 문제은행과 동일한 유형·난이도 필터.
  final Set<String> activeTypeFilters = <String>{};
  final Set<String> activeDifficultyFilters = <String>{};

  /// 장바구니에 담긴 문항만 보기.
  bool showOnlyCart = false;

  LearningProblemExportSettings exportSettings =
      LearningProblemExportSettings.initial();
  bool isExporting = false;
  LearningProblemExportJob? activeExportJob;

  final TextbookExplorerExportLauncher _exportLauncher =
      TextbookExplorerExportLauncher();

  /// selKey -> 문항 조회용.
  final Map<String, TbExItem> _itemBySelKey = <String, TbExItem>{};

  // PDF
  final PdfViewerController pdfController = PdfViewerController();
  TextbookPdfSource? pdfSource;
  Object? pdfError;
  bool pdfLoading = false;
  bool _pdfRequested = false;

  /// PDF 오버레이 호버 대상. [notifyListeners] 없이 오버레이만 갱신한다.
  final ValueNotifier<String?> pdfHoverSelKey = ValueNotifier<String?>(null);

  Map<int, List<TbExItem>> get itemsByPage => data.itemsByPage;

  void setPdfHover(String? selKey) {
    if (pdfHoverSelKey.value == selKey) return;
    pdfHoverSelKey.value = selKey;
  }

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

  @override
  void dispose() {
    pdfHoverSelKey.dispose();
    super.dispose();
  }

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

  static String _normalizeDifficultyLabel(String raw) {
    final compact = raw.trim().replaceAll(RegExp(r'\s+'), '');
    if (compact == '대표문제') return '대표 문제';
    return raw.trim();
  }

  List<TbExItem> get filteredVisibleItems {
    final base = visibleItems;
    if (activeTypeFilters.isEmpty && activeDifficultyFilters.isEmpty) {
      return base;
    }
    return base.where((item) {
      if (activeTypeFilters.isNotEmpty &&
          !activeTypeFilters.contains(item.typeGroupKey)) {
        return false;
      }
      if (activeDifficultyFilters.isNotEmpty) {
        final difficulty = _normalizeDifficultyLabel(item.difficultyLabel);
        if (!activeDifficultyFilters.contains(difficulty)) return false;
      }
      return true;
    }).toList(growable: false);
  }

  /// 필터·장바구니 보기가 반영된 실제 표시 대상.
  List<TbExItem> get displayItems {
    if (!showOnlyCart) return filteredVisibleItems;
    return cartKeys
        .map((key) => _itemBySelKey[key])
        .whereType<TbExItem>()
        .toList(growable: false);
  }

  Set<String> get displaySelKeys =>
      displayItems.map((item) => item.selKey).toSet();

  bool get questionFilterActive =>
      activeTypeFilters.isNotEmpty || activeDifficultyFilters.isNotEmpty;

  List<String> get typeFilterOptions {
    final out = <String>{};
    for (final item in visibleItems) {
      if (item.typeGroupKind != 'type' || item.typeGroupLabel.isEmpty) {
        continue;
      }
      out.add(item.typeGroupKey);
    }
    final list = out.toList();
    list.sort((a, b) {
      final aLabel = a.split('|').first.trim();
      final bLabel = b.split('|').first.trim();
      return aLabel.compareTo(bLabel);
    });
    return list;
  }

  List<String> get difficultyFilterOptions {
    const order = <String, int>{
      '하': 0,
      '중': 1,
      '상': 2,
      '대표 문제': 3,
      '창의문제': 4,
      '서술형': 5,
    };
    final out = <String>{};
    for (final item in visibleItems) {
      final label = _normalizeDifficultyLabel(item.difficultyLabel);
      if (label.isNotEmpty) out.add(label);
    }
    final list = out.toList();
    list.sort((a, b) {
      final ai = order[a] ?? 100;
      final bi = order[b] ?? 100;
      if (ai != bi) return ai.compareTo(bi);
      return a.compareTo(b);
    });
    return list;
  }

  bool get allVisibleSelected {
    final visible = displayItems;
    return visible.isNotEmpty &&
        visible.every((item) => selectedKeys.contains(item.selKey));
  }

  int get makeTargetCount => makeTargetQuestionUids.length;

  List<String> get makeTargetQuestionUids {
    if (cartKeys.isNotEmpty) {
      return cartKeys
          .map((key) => _itemBySelKey[key]?.questionUid.trim() ?? '')
          .where((uid) => uid.isNotEmpty)
          .toList(growable: false);
    }
    return selectedKeys
        .map((key) => _itemBySelKey[key]?.questionUid.trim() ?? '')
        .where((uid) => uid.isNotEmpty)
        .toList(growable: false);
  }

  bool get hasSelectionFilter => checkedPageKeys.isNotEmpty;

  /// 원본 PDF에 표시할 raw 페이지. 체크된 페이지 + 소단원 전체 선택 시 개념 페이지.
  Set<int> get visiblePdfRawPages {
    final out = <int>{};
    for (final pageKey in checkedPageKeys) {
      final sep = pageKey.lastIndexOf('#');
      if (sep < 0) continue;
      final raw = int.tryParse(pageKey.substring(sep + 1));
      if (raw != null && raw > 0) out.add(raw);
    }
    for (final big in data.units) {
      for (final mid in big.mids) {
        for (final small in mid.smalls) {
          if (!isSmallFullyChecked(small)) continue;
          out.addAll(small.metadataPageNumbers);
        }
      }
    }
    return out;
  }

  List<int> get visiblePdfRawPagesSorted {
    final pages = visiblePdfRawPages.toList()..sort();
    return pages;
  }

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
    final count = displayItems.length;
    return count <= 0 ? '' : '$count문항';
  }

  void toggleTypeFilter(String value) {
    if (!activeTypeFilters.add(value)) {
      activeTypeFilters.remove(value);
    }
    notifyListeners();
  }

  void toggleDifficultyFilter(String value) {
    if (!activeDifficultyFilters.add(value)) {
      activeDifficultyFilters.remove(value);
    }
    notifyListeners();
  }

  void clearQuestionFilters() {
    if (!questionFilterActive) return;
    activeTypeFilters.clear();
    activeDifficultyFilters.clear();
    notifyListeners();
  }

  void toggleSelectAllVisible() {
    final visible = displayItems;
    if (visible.isEmpty) return;
    final allSelected =
        visible.every((item) => selectedKeys.contains(item.selKey));
    for (final item in visible) {
      if (allSelected) {
        selectedKeys.remove(item.selKey);
      } else {
        selectedKeys.add(item.selKey);
      }
    }
    notifyListeners();
  }

  void toggleShowOnlyCart(BuildContext context) {
    if (showOnlyCart) {
      showOnlyCart = false;
      notifyListeners();
      return;
    }
    if (cartKeys.isEmpty) {
      showAppSnackBar(context, '장바구니에 추가된 문항이 없습니다.');
      return;
    }
    showOnlyCart = true;
    notifyListeners();
  }

  void clearCart() {
    if (cartKeys.isEmpty) return;
    cartKeys.clear();
    showOnlyCart = false;
    notifyListeners();
  }

  void patchExportSettings(LearningProblemExportSettings next) {
    exportSettings = next;
    notifyListeners();
  }

  void setExportLayoutColumns(String value) {
    final options = maxQuestionsPerPageOptionsOf(value);
    final current = exportSettings.maxQuestionsPerPageLabel.trim();
    final parsed = int.tryParse(current);
    final nextMax = (current == '많이')
        ? '많이'
        : (parsed != null && options.contains(parsed))
            ? '$parsed'
            : '${options.last}';
    exportSettings = exportSettings.copyWith(
      layoutColumnLabel: value,
      maxQuestionsPerPageLabel: nextMax,
    );
    notifyListeners();
  }

  Future<void> openExportLayoutPreview(BuildContext context) async {
    final uids = makeTargetQuestionUids;
    if (uids.isEmpty) {
      showAppSnackBar(context, '레이아웃 미리보기할 문항을 먼저 선택해주세요.');
      return;
    }
    if (isExporting) return;
    isExporting = true;
    notifyListeners();
    try {
      await _exportLauncher.openLayoutPreview(
        context: context,
        academyId: academyId,
        questionUids: uids,
        settings: exportSettings,
        onSettingsChanged: patchExportSettings,
        onActiveJobChanged: (job) {
          activeExportJob = job;
          notifyListeners();
        },
      );
    } finally {
      isExporting = false;
      notifyListeners();
    }
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
    final selected = displayItems
        .where((item) => selectedKeys.contains(item.selKey))
        .toList(growable: false);
    if (selected.isEmpty) {
      showAppSnackBar(context, '추가할 문항을 먼저 체크해주세요.');
      return;
    }
    var added = 0;
    for (final item in selected) {
      if (cartKeys.contains(item.selKey)) continue;
      cartKeys.add(item.selKey);
      added += 1;
    }
    notifyListeners();
    showAppSnackBar(
      context,
      added > 0 ? '장바구니에 $added문항을 추가했습니다.' : '이미 장바구니에 담긴 문항입니다.',
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
const double _tbExTitleOverlayTop = FabTabBarTokens.previewAcademyTopInset - 12;
const double _tbExTitleLineHeight =
    FabTabBarTokens.previewAcademyMainTitleFontSize * 1.15;
const double _tbExHeaderBackButtonGap = 16.0;
const double _tbExScrollTopPadding =
    _tbExTitleOverlayTop + _tbExTitleLineHeight + 12;

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
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: _buildBody(context, style),
            ),
            Positioned(
              top: _tbExTitleOverlayTop,
              left: _tbExContentHorizontalInset +
                  FabTabBarTokens.fabBarHeight +
                  _tbExHeaderBackButtonGap,
              right: 12,
              child: IgnorePointer(
                child: FabStyleScreenMainTitle(
                  title: controller.currentScopeTitle,
                  overlay: true,
                  maxLines: 1,
                ),
              ),
            ),
            Positioned(
              top: _tbExTitleOverlayTop +
                  (_tbExTitleLineHeight - FabTabBarTokens.fabBarHeight) / 2,
              left: _tbExContentHorizontalInset,
              child: _SolidCircleActionButton(
                icon: Icons.arrow_back_rounded,
                tooltip: '교재 목록으로 돌아가기',
                size: FabTabBarTokens.fabBarHeight,
                iconSize: FabTabBarTokens.previewAcademyBaseFontSize + 8,
                onPressed: () => controller.onClose?.call(),
              ),
            ),
            if (controller.hasSelectionFilter &&
                !controller.loading &&
                controller.data.hasQuestions)
              Positioned(
                top: 12,
                right: 12,
                child: _TbExExportOptionsFab(controller: controller),
              ),
          ],
        );
      },
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
    final items = controller.displayItems;
    if (items.isEmpty) {
      return Center(
        child: Text(
          controller.showOnlyCart
              ? '장바구니에 표시할 문항이 없습니다.'
              : controller.questionFilterActive
                  ? '필터 조건에 맞는 문항이 없습니다.'
                  : '선택한 범위에 표시할 문항이 없습니다.',
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
                          onEnter: (_) => controller.enterItemDrag(item.selKey),
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
    if (!controller.hasSelectionFilter) {
      return Center(
        child: Text(
          '왼쪽 단원 트리에서 소단원 또는 페이지를 체크하세요.',
          style: TextStyle(color: style.hint, fontSize: 14),
        ),
      );
    }
    if (controller.visiblePdfRawPages.isEmpty) {
      return Center(
        child: Text(
          '표시할 페이지가 없습니다.',
          style: TextStyle(color: style.hint, fontSize: 14),
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
    return Positioned.fill(
      child: Listener(
        onPointerUp: (_) => controller.finishItemDrag(),
        onPointerCancel: (_) => controller.cancelItemDrag(),
        child: _PdfViewer(controller: controller),
      ),
    );
  }
}

// =============================================================== PDF VIEWER
class _PdfViewer extends StatefulWidget {
  const _PdfViewer({required this.controller});

  final TextbookExplorerController controller;

  static const double _colGap = 4.0;
  static const double _rowGap = 16.0;
  static const double _pageMargin = 4.0;

  static PdfPageLayout layoutTwoPageSpread(
    List<PdfPage> pages,
    PdfViewerParams params,
    Set<int> visibleRawPages,
  ) {
    if (pages.isEmpty) {
      return PdfPageLayout(
        pageLayouts: const <Rect>[],
        documentSize: Size.zero,
      );
    }

    final visibleNumbers = visibleRawPages.toList()..sort();
    final visible = <PdfPage>[
      for (final pageNumber in visibleNumbers)
        for (final page in pages)
          if (page.pageNumber == pageNumber) page,
    ];

    if (visible.isEmpty) {
      return PdfPageLayout(
        pageLayouts: List<Rect>.filled(
          pages.length,
          const Rect.fromLTWH(0, 0, 1, 1),
        ),
        documentSize: const Size(1, 1),
      );
    }

    final colGap = _colGap;
    final rowGap = _rowGap;
    final layoutsByPage = <int, Rect>{};
    var y = params.margin;
    var maxRowWidth = 0.0;

    for (var i = 0; i < visible.length; i += 2) {
      final left = visible[i];
      final right = (i + 1) < visible.length ? visible[i + 1] : null;
      final rowWidth =
          right == null ? left.width : left.width + colGap + right.width;
      maxRowWidth = math.max(maxRowWidth, rowWidth);
    }

    final totalWidth = math.max(maxRowWidth + params.margin * 2, 1.0);

    for (var i = 0; i < visible.length; i += 2) {
      final left = visible[i];
      final right = (i + 1) < visible.length ? visible[i + 1] : null;
      final rowWidth =
          right == null ? left.width : left.width + colGap + right.width;
      final startX = (totalWidth - rowWidth) / 2;
      layoutsByPage[left.pageNumber] =
          Rect.fromLTWH(startX, y, left.width, left.height);
      if (right != null) {
        layoutsByPage[right.pageNumber] = Rect.fromLTWH(
          startX + left.width + colGap,
          y,
          right.width,
          right.height,
        );
      }
      final rowHeight = math.max(left.height, right?.height ?? 0);
      y += rowHeight + rowGap;
    }

    final documentHeight = math.max(y + params.margin, 1.0);

    return PdfPageLayout(
      pageLayouts: [
        for (final page in pages)
          layoutsByPage[page.pageNumber] ??
              Rect.fromLTWH(0, documentHeight + page.pageNumber, 1, 1),
      ],
      documentSize: Size(totalWidth, documentHeight + pages.length + 1),
    );
  }

  static int initialPageNumber(Set<int> visibleRawPages) {
    final sorted = visibleRawPages.toList()..sort();
    return sorted.isEmpty ? 1 : sorted.first;
  }

  static double spreadFitZoom(
    PdfDocument document,
    Set<int> visibleRawPages,
    Size viewSize, {
    double margin = _pageMargin,
    double minScale = 0.1,
    double maxScale = 8,
  }) {
    if (viewSize.width <= 0) return minScale;
    final layoutParams = PdfViewerParams(margin: margin);
    final layout = layoutTwoPageSpread(
      document.pages,
      layoutParams,
      visibleRawPages,
    );
    final docWidth = layout.documentSize.width;
    if (docWidth <= 0) return minScale;
    // 표시 영역 너비에 맞춤 — 가로 스크롤 없음, 높이는 넘치면 세로 스크롤.
    return (viewSize.width / docWidth).clamp(minScale, maxScale);
  }

  static Matrix4 widthFitMatrix(
    PdfDocument document,
    PdfViewerController ctrl,
    Set<int> visibleRawPages,
    Size viewSize,
  ) {
    final zoom = spreadFitZoom(document, visibleRawPages, viewSize);
    final layout = layoutTwoPageSpread(
      document.pages,
      PdfViewerParams(margin: _pageMargin),
      visibleRawPages,
    );
    final initialPage = initialPageNumber(visibleRawPages);
    final pageRect = layout.pageLayouts[initialPage - 1];
    final anchorY = pageRect.top + pageRect.height * 0.05;
    return ctrl.calcMatrixFor(
      Offset(layout.documentSize.width / 2, anchorY),
      zoom: zoom,
      viewSize: viewSize,
    );
  }

  @override
  State<_PdfViewer> createState() => _PdfViewerState();
}

class _PdfViewerState extends State<_PdfViewer> {
  Set<int> _layoutVisiblePages = const <int>{};
  Key _viewerKey = const ValueKey<String>('tbex-pdf-empty');
  bool _widthFitReady = false;

  void _syncViewerKey(Set<int> visiblePages) {
    if (Set<int>.from(visiblePages).containsAll(_layoutVisiblePages) &&
        visiblePages.length == _layoutVisiblePages.length) {
      return;
    }
    _layoutVisiblePages = Set<int>.from(visiblePages);
    final sorted = visiblePages.toList()..sort();
    _viewerKey = ValueKey<String>('tbex-pdf-${sorted.join(',')}');
    _widthFitReady = false;
  }

  Future<void> _applyWidthFit(
    PdfDocument document,
    PdfViewerController ctrl,
    Set<int> visiblePages,
    Size viewSize,
  ) async {
    if (!ctrl.isReady || viewSize.width <= 0) return;
    final matrix = _PdfViewer.widthFitMatrix(
      document,
      ctrl,
      visiblePages,
      viewSize,
    );
    await ctrl.goTo(matrix, duration: Duration.zero);
  }

  Future<void> _scheduleWidthFit(
    PdfDocument document,
    PdfViewerController ctrl,
    Set<int> visiblePages,
    Size viewSize,
  ) async {
    // pdfrx 초기화 시 _goToPage가 너비 맞춤 줌을 덮어쓰므로 여러 번 재적용한다.
    for (final delay in [
      Duration.zero,
      const Duration(milliseconds: 16),
      const Duration(milliseconds: 80),
      const Duration(milliseconds: 180),
      const Duration(milliseconds: 360),
    ]) {
      await Future<void>.delayed(delay);
      if (!mounted) return;
      final latestViewSize =
          ctrl.isReady && ctrl.viewSize.width > 0 ? ctrl.viewSize : viewSize;
      if (!ctrl.isReady || latestViewSize.width <= 0) continue;
      await _applyWidthFit(document, ctrl, visiblePages, latestViewSize);
    }
    if (mounted && !_widthFitReady) {
      setState(() => _widthFitReady = true);
    }
  }

  PdfViewerParams _params(
    Set<int> visibleRawPages,
    Color backgroundColor,
    Size hostSize,
  ) {
    final initialPage = _PdfViewer.initialPageNumber(visibleRawPages);
    final fitViewSize = Size(
      hostSize.width > 0 ? hostSize.width : 1,
      hostSize.height > 0 ? hostSize.height : 1,
    );
    return PdfViewerParams(
      margin: _PdfViewer._pageMargin,
      backgroundColor: backgroundColor,
      layoutPages: (pages, params) =>
          _PdfViewer.layoutTwoPageSpread(pages, params, visibleRawPages),
      pageAnchor: PdfPageAnchor.top,
      panAxis: PanAxis.vertical,
      pageDropShadow: null,
      panEnabled: !widget.controller.itemDragActive,
      maxScale: 8,
      minScale: 0.05,
      useAlternativeFitScaleAsMinScale: false,
      calculateInitialPageNumber: (_, __) => initialPage,
      calculateInitialZoom: (document, ctrl, fitZoom, coverZoom) {
        return _PdfViewer.spreadFitZoom(
          document,
          visibleRawPages,
          fitViewSize,
        );
      },
      normalizeMatrix: (matrix, viewSize, layout, ctrl) {
        if (ctrl == null) return matrix;
        final docWidth = layout.documentSize.width;
        final zoom = matrix.zoom.clamp(0.05, 8.0);
        final pos = matrix.calcPosition(viewSize);
        final scaledW = docWidth * zoom;
        final hw = viewSize.width / 2 / zoom;
        final hh = viewSize.height / 2 / zoom;
        final x = scaledW <= viewSize.width + 1
            ? docWidth / 2
            : pos.dx.clamp(hw, docWidth - hw);
        final minY = hh;
        final maxY = layout.documentSize.height - hh;
        final y = minY > maxY
            ? layout.documentSize.height / 2
            : pos.dy.clamp(minY, maxY);
        return ctrl.calcMatrixFor(
          Offset(x, y),
          zoom: zoom,
          viewSize: viewSize,
        );
      },
      onViewerReady: (document, ctrl) {
        final viewSize = ctrl.isReady && ctrl.viewSize.width > 0
            ? ctrl.viewSize
            : fitViewSize;
        unawaited(_scheduleWidthFit(document, ctrl, visibleRawPages, viewSize));
      },
      onViewSizeChanged: (viewSize, oldViewSize, ctrl) {
        if (!ctrl.isReady || viewSize == oldViewSize) return;
        ctrl.useDocument(
          (document) => _applyWidthFit(
            document,
            ctrl,
            visibleRawPages,
            viewSize,
          ),
        );
      },
      pageOverlaysBuilder: (context, pageRect, page) {
        if (!visibleRawPages.contains(page.pageNumber)) {
          return const <Widget>[];
        }
        final items = widget.controller.itemsByPage[page.pageNumber];
        if (items == null || items.isEmpty) return const <Widget>[];
        final displayKeys = widget.controller.displaySelKeys;
        final w = pageRect.width;
        final h = pageRect.height;
        return [
          for (final item in items)
            if (item.hasRegion &&
                !item.isSetHeader &&
                item.problemNumber.trim().isNotEmpty &&
                displayKeys.contains(item.selKey))
              _PdfProblemOverlay(
                controller: widget.controller,
                item: item,
                pageItems: items,
                pageWidth: w,
                pageHeight: h,
              ),
        ];
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.controller.pdfSource!;
    final backgroundColor = context.yggSurfaceBase;
    return ColoredBox(
      color: backgroundColor,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final hostSize = Size(constraints.maxWidth, constraints.maxHeight);
          return ListenableBuilder(
            listenable: widget.controller,
            builder: (context, _) {
              final visiblePages = widget.controller.visiblePdfRawPages;
              _syncViewerKey(visiblePages);
              final params = _params(visiblePages, backgroundColor, hostSize);
              final initialPage = _PdfViewer.initialPageNumber(visiblePages);
              switch (source.type) {
                case TextbookPdfSourceType.localFile:
                  final path = source.localPath ?? '';
                  if (path.isEmpty) return const SizedBox.shrink();
                  return Opacity(
                    opacity: _widthFitReady ? 1 : 0,
                    child: PdfViewer.file(
                      path,
                      key: _viewerKey,
                      initialPageNumber: initialPage,
                      controller: widget.controller.pdfController,
                      params: params,
                    ),
                  );
                case TextbookPdfSourceType.legacyUrl:
                case TextbookPdfSourceType.remoteUrl:
                  final uri = Uri.tryParse(source.url ?? '');
                  if (uri == null) return const SizedBox.shrink();
                  return Opacity(
                    opacity: _widthFitReady ? 1 : 0,
                    child: PdfViewer.uri(
                      uri,
                      key: _viewerKey,
                      initialPageNumber: initialPage,
                      controller: widget.controller.pdfController,
                      params: params,
                    ),
                  );
              }
            },
          );
        },
      ),
    );
  }
}

class _PdfProblemOverlay extends StatelessWidget {
  const _PdfProblemOverlay({
    required this.controller,
    required this.item,
    required this.pageItems,
    required this.pageWidth,
    required this.pageHeight,
  });

  final TextbookExplorerController controller;
  final TbExItem item;
  final List<TbExItem> pageItems;
  final double pageWidth;
  final double pageHeight;

  static const Color _accent = Color(0xFF33A373);
  static const double _numberPadRatio = 0.03;
  /// B단계 등 큰 문항에서 쓰는 통일 최대 체크 배지 크기.
  static const double _checkMaxSize = 40.0;

  /// 최소 = 문항번호 하이라이트 높이, 최대 = 크롭 안에 들어가는 [_checkMaxSize].
  double _checkBadgeSize(double numberHeight, double hitW, double hitH) {
    final cropLimit = math.min(hitW, hitH);
    if (cropLimit <= 0) return numberHeight;
    final minSize = math.min(numberHeight, cropLimit);
    final ideal = math.min(_checkMaxSize, cropLimit);
    return ideal.clamp(minSize, cropLimit);
  }

  ({double left, double top, double width, double height}) _bboxRect() {
    if (item.hasNumberRegion) {
      return (
        left: pageWidth * item.numberXmin!,
        top: pageHeight * item.numberYmin!,
        width: pageWidth * (item.numberXmax! - item.numberXmin!),
        height: pageHeight * (item.numberYmax! - item.numberYmin!),
      );
    }
    final itemW = pageWidth * (item.xmax - item.xmin);
    final itemH = pageHeight * (item.ymax - item.ymin);
    return (
      left: pageWidth * item.xmin,
      top: pageHeight * item.ymin,
      width: math.min(itemW * 0.22, 48.0),
      height: math.min(itemH * 0.18, 32.0),
    );
  }

  /// bbox 안에서 문항번호(숫자)만 — 난이도·서술형 라벨은 제외.
  ({double left, double top, double width, double height, double fontSize})
      _numberPaintRect() {
    final bbox = _bboxRect();
    final padX = bbox.width * _numberPadRatio;
    final padY = bbox.height * _numberPadRatio;
    final fontSize = (bbox.height * 0.62).clamp(5.0, 16.0).toDouble();

    var left = bbox.left - padX;
    var top = bbox.top - padY;
    var width = bbox.width + padX * 2;
    var height = bbox.height + padY * 2;

    if (left < 0) {
      width += left;
      left = 0;
    }
    if (top < 0) {
      height += top;
      top = 0;
    }
    if (left + width > pageWidth) {
      width = pageWidth - left;
    }
    if (top + height > pageHeight) {
      height = pageHeight - top;
    }

    return (
      left: left,
      top: top,
      width: math.max(width, 1.0),
      height: math.max(height, 1.0),
      fontSize: fontSize,
    );
  }

  TbExItem? _itemAtPageOffset(Offset pageOffset) {
    for (final candidate in pageItems.reversed) {
      if (!candidate.hasRegion ||
          candidate.isSetHeader ||
          candidate.problemNumber.trim().isEmpty) {
        continue;
      }
      final rect = Rect.fromLTRB(
        pageWidth * candidate.xmin,
        pageHeight * candidate.ymin,
        pageWidth * candidate.xmax,
        pageHeight * candidate.ymax,
      );
      if (rect.contains(pageOffset)) return candidate;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final hitLeft = pageWidth * item.xmin;
    final hitTop = pageHeight * item.ymin;
    final hitW = pageWidth * (item.xmax - item.xmin);
    final hitH = pageHeight * (item.ymax - item.ymin);
    final numberRect = _numberPaintRect();
    final hlLeft = numberRect.left - hitLeft;
    final hlTop = numberRect.top - hitTop;
    final checkSize =
        _checkBadgeSize(numberRect.height, hitW, hitH);

    return Positioned(
      left: hitLeft,
      top: hitTop,
      width: hitW,
      height: hitH,
      child: AnimatedBuilder(
        animation: Listenable.merge([
          controller,
          controller.pdfHoverSelKey,
        ]),
        builder: (context, _) {
          final hovered = controller.pdfHoverSelKey.value == item.selKey &&
              !controller.isItemEffectivelySelected(item.selKey);
          final selected = controller.isItemEffectivelySelected(item.selKey);
          return MouseRegion(
            onEnter: (_) {
              controller.setPdfHover(item.selKey);
              controller.enterItemDrag(item.selKey);
            },
            onExit: (_) {
              if (controller.pdfHoverSelKey.value == item.selKey) {
                controller.setPdfHover(null);
              }
            },
            child: Listener(
              onPointerDown: (event) {
                if (event.buttons == kPrimaryMouseButton) {
                  controller.startItemDrag(item.selKey);
                }
              },
              onPointerMove: (event) {
                if (!controller.itemDragActive) return;
                final pageOffset = Offset(
                  hitLeft + event.localPosition.dx,
                  hitTop + event.localPosition.dy,
                );
                final hoveredItem = _itemAtPageOffset(pageOffset);
                if (hoveredItem != null) {
                  controller.enterItemDrag(hoveredItem.selKey);
                }
              },
              onPointerUp: (_) => controller.finishItemDrag(),
              onPointerCancel: (_) => controller.cancelItemDrag(),
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                dragStartBehavior: DragStartBehavior.down,
                onTap: () => controller.toggleSelectKey(item.selKey),
                onPanStart: (_) {
                  if (!controller.itemDragActive) {
                    controller.startItemDrag(item.selKey);
                  }
                },
                onPanUpdate: (details) {
                  final pageOffset = Offset(
                    hitLeft + details.localPosition.dx,
                    hitTop + details.localPosition.dy,
                  );
                  final hoveredItem = _itemAtPageOffset(pageOffset);
                  if (hoveredItem != null) {
                    controller.enterItemDrag(hoveredItem.selKey);
                  }
                },
                onPanEnd: (_) => controller.finishItemDrag(),
                onPanCancel: controller.cancelItemDrag,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    if (selected)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: Center(
                            child: Container(
                              width: checkSize,
                              height: checkSize,
                              decoration: const BoxDecoration(
                                color: _accent,
                                shape: BoxShape.circle,
                              ),
                              alignment: Alignment.center,
                              child: Icon(
                                Icons.check,
                                size: (checkSize * 0.62)
                                    .clamp(numberRect.height * 0.45, checkSize * 0.72),
                                weight: 900,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (hovered)
                      Positioned(
                        left: hlLeft,
                        top: hlTop,
                        width: numberRect.width,
                        height: numberRect.height,
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: const Color(0x337AA9E6),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                      ),
                    if (selected)
                      Positioned(
                        left: hlLeft,
                        top: hlTop,
                        width: numberRect.width,
                        height: numberRect.height,
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: _accent,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Center(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 2,
                                  ),
                                  child: Text(
                                    item.problemNumber.trim(),
                                    maxLines: 1,
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: numberRect.fontSize,
                                      fontWeight: FontWeight.w800,
                                      height: 1,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
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
class TbExModeFabBar {
  TbExModeFabBar._();

  static const double _compactPillWidth = 88;

  static List<Widget> leadingPills({
    required TbExRightMode mode,
    required bool enabled,
    required VoidCallback onQuestionsMode,
    required VoidCallback onPdfMode,
  }) {
    final disabled = !enabled;
    return [
      FabStyleActionTabPill(
        icon: Icons.grid_view_rounded,
        label: '문항',
        selected: mode == TbExRightMode.questions,
        enabled: !disabled,
        onTap: onQuestionsMode,
        width: _compactPillWidth,
      ),
      FabStyleActionTabPill(
        icon: Icons.picture_as_pdf_outlined,
        label: '원본',
        selected: mode == TbExRightMode.pdf,
        enabled: !disabled,
        onTap: onPdfMode,
        width: _compactPillWidth,
      ),
    ];
  }
}

class _TbExExportOptionsFab extends StatelessWidget {
  const _TbExExportOptionsFab({required this.controller});

  final TextbookExplorerController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final busy = controller.isExporting;
        return ProblemBankExportOptionsFab(
          isBusy: busy,
          panel: _TbExExportOptionsPanel(controller: controller),
          filterButton: ProblemBankFilterMenuButton(
            disabled: busy,
            filterActive: controller.questionFilterActive,
            typeFilterOptions: controller.typeFilterOptions,
            difficultyFilterOptions: controller.difficultyFilterOptions,
            selectedTypeFilters: controller.activeTypeFilters,
            selectedDifficultyFilters: controller.activeDifficultyFilters,
            onToggleTypeFilter: controller.toggleTypeFilter,
            onToggleDifficultyFilter: controller.toggleDifficultyFilter,
            onClearFilters: controller.clearQuestionFilters,
          ),
        );
      },
    );
  }
}

class _TbExExportOptionsPanel extends StatelessWidget {
  const _TbExExportOptionsPanel({required this.controller});

  final TextbookExplorerController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final settings = controller.exportSettings;
        return ProblemBankExportOptionsPanel(
          settings: settings,
          selectedCount: controller.makeTargetCount,
          isBusy: controller.isExporting,
          isSavingLocally: false,
          activeJob: controller.activeExportJob,
          onTemplateChanged: (value) {
            if (value == '과제형') {
              controller.patchExportSettings(
                settings.copyWith(
                  templateLabel: value,
                  paperLabel: 'A4',
                  layoutColumnLabel: '2단',
                  maxQuestionsPerPageLabel: '4',
                ),
              );
            } else if (value == '모의고사형' || value == '수능형') {
              controller.patchExportSettings(
                settings.copyWith(
                  templateLabel: value,
                  paperLabel: 'B4',
                  layoutColumnLabel: '2단',
                  maxQuestionsPerPageLabel: '4',
                ),
              );
            } else {
              controller.patchExportSettings(
                settings.copyWith(templateLabel: value),
              );
            }
          },
          onPaperChanged: (value) => controller.patchExportSettings(
            settings.copyWith(paperLabel: value),
          ),
          onQuestionModeChanged: (value) => controller.patchExportSettings(
            settings.copyWith(questionModeLabel: value),
          ),
          onLayoutColumnsChanged: controller.setExportLayoutColumns,
          onMaxQuestionsPerPageChanged: (value) =>
              controller.patchExportSettings(
            settings.copyWith(maxQuestionsPerPageLabel: value),
          ),
          onFontFamilyChanged: (value) => controller.patchExportSettings(
            settings.copyWith(fontFamilyLabel: value),
          ),
          onFontSizeChanged: (value) => controller.patchExportSettings(
            settings.copyWith(fontSizeLabel: value),
          ),
          onIncludeAnswerSheetChanged: (value) =>
              controller.patchExportSettings(
            settings.copyWith(includeAnswerSheet: value),
          ),
          onIncludeExplanationChanged: (value) =>
              controller.patchExportSettings(
            settings.copyWith(includeExplanation: value),
          ),
          onPageMarginChanged: (value) => controller.patchExportSettings(
            settings.copyWith(
              layoutTuning: settings.layoutTuning.copyWith(pageMargin: value),
            ),
          ),
          onColumnGapChanged: (value) => controller.patchExportSettings(
            settings.copyWith(
              layoutTuning: settings.layoutTuning.copyWith(columnGap: value),
            ),
          ),
          onQuestionGapChanged: (value) => controller.patchExportSettings(
            settings.copyWith(
              layoutTuning: settings.layoutTuning.copyWith(questionGap: value),
            ),
          ),
          onNumberLaneWidthChanged: (value) => controller.patchExportSettings(
            settings.copyWith(
              layoutTuning:
                  settings.layoutTuning.copyWith(numberLaneWidth: value),
            ),
          ),
          onNumberGapChanged: (value) => controller.patchExportSettings(
            settings.copyWith(
              layoutTuning: settings.layoutTuning.copyWith(numberGap: value),
            ),
          ),
          onHangingIndentChanged: (value) => controller.patchExportSettings(
            settings.copyWith(
              layoutTuning:
                  settings.layoutTuning.copyWith(hangingIndent: value),
            ),
          ),
          onLineHeightChanged: (value) => controller.patchExportSettings(
            settings.copyWith(
              layoutTuning: settings.layoutTuning.copyWith(lineHeight: value),
            ),
          ),
          onChoiceSpacingChanged: (value) => controller.patchExportSettings(
            settings.copyWith(
              layoutTuning:
                  settings.layoutTuning.copyWith(choiceSpacing: value),
            ),
          ),
          onTargetDpiChanged: (value) => controller.patchExportSettings(
            settings.copyWith(
              figureQuality: settings.figureQuality.copyWith(
                targetDpi: value,
                minDpi: math.min(settings.figureQuality.minDpi, value),
              ),
            ),
          ),
        );
      },
    );
  }
}

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
    final disabled = !enabled;

    return FabStyleActionTabBar(
      children: [
        FabStyleActionTabPill(
          icon: Icons.grid_view_rounded,
          label: '문항',
          selected: mode == TbExRightMode.questions,
          enabled: !disabled,
          onTap: onQuestionsMode,
          width: 88,
        ),
        FabStyleActionTabPill(
          icon: Icons.picture_as_pdf_outlined,
          label: '원본',
          selected: mode == TbExRightMode.pdf,
          enabled: !disabled,
          onTap: onPdfMode,
          width: 88,
        ),
        FabStyleActionTabPill(
          icon: Icons.add_rounded,
          label: selectedCount > 0 ? '추가 $selectedCount' : '추가',
          enabled: !disabled,
          onTap: onAdd,
          width: selectedCount > 0 ? 128 : 112,
        ),
        FabStyleActionTabPill(
          icon: Icons.shopping_cart_outlined,
          label: cartCount > 0 ? '장바구니 $cartCount' : '장바구니',
          enabled: !disabled && cartCount > 0,
          onTap: onOpenCart,
          width: 144,
        ),
      ],
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
          final enabled = !controller.loading && controller.data.hasQuestions;
          final busy = controller.isExporting;
          return Padding(
            padding: const EdgeInsets.only(left: _tbExContentHorizontalInset),
            child: ProblemBankBottomFabBar(
              alignStart: true,
              leading: TbExModeFabBar.leadingPills(
                mode: controller.mode,
                enabled: enabled,
                onQuestionsMode: () =>
                    controller.switchMode(TbExRightMode.questions),
                onPdfMode: () => controller.switchMode(TbExRightMode.pdf),
              ),
              cartCount: controller.cartCount,
              cartActive: controller.showOnlyCart,
              allVisibleSelected: controller.allVisibleSelected,
              isBusy: busy || !enabled,
              onToggleSelectAll: controller.toggleSelectAllVisible,
              onToggleCart: () =>
                  controller.toggleShowOnlyCart(overlayContext),
              onClearCart: controller.clearCart,
              onAddToCart: () => controller.addSelectedToCart(overlayContext),
              onCreate: () =>
                  controller.openExportLayoutPreview(overlayContext),
            ),
          );
        },
      ),
    );
  }
}
