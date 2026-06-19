import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

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

  @override
  State<ProblemBankSchoolSheet> createState() => _ProblemBankSchoolSheetState();
}

class _ProblemBankSchoolSheetState extends State<ProblemBankSchoolSheet> {
  static const _panelBg = Color(0xFF222222);
  static const _border = Color(0xFF333333);
  static const _selectedBg = Color(0xFF173C36);
  static const _text = Color(0xFFEAF2F2);

  static const _unspecifiedSchool = '학교 미지정';

  final Set<String> _expandedSchools = <String>{};
  final Set<String> _expandedYearBuckets = <String>{};
  bool _privatePageDragActive = false;
  bool _privatePageDragSelectMode = true;
  bool _privatePageSuppressNextTap = false;
  Set<String> _privatePageDragBaseKeys = <String>{};
  final Set<String> _privatePageDragKeys = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _expandForSelectedDocument();
    });
  }

  @override
  void didUpdateWidget(covariant ProblemBankSchoolSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sidebarRevision != widget.sidebarRevision) {
      _expandedSchools.clear();
      _expandedYearBuckets.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _expandForSelectedDocument();
      });
    } else if (oldWidget.selectedDocumentId != widget.selectedDocumentId ||
        oldWidget.documents != widget.documents) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _expandForSelectedDocument();
      });
    }
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
        _expandedSchools.add(school);
        _expandedYearBuckets.add(yearKey);
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
    if (widget.selectedSourceTypeCode != 'private_material') {
      return _buildDocumentTreePanel();
    }

    return Container(
      decoration: BoxDecoration(
        color: _panelBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: _border),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.selectedSourceTypeCode == 'private_material'
                      ? '교재 단원'
                      : '추출 문서',
                  style: const TextStyle(
                    color: _text,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
                if (widget.selectedSourceTypeCode == 'private_material') ...[
                  const SizedBox(height: 6),
                  Text(
                    widget.privateMaterialTitle.trim().isNotEmpty
                        ? widget.privateMaterialTitle.trim()
                        : '교재명 드롭다운에서 교재를 선택하세요.',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: const Color(0xFF9FB3B3).withValues(alpha: 0.95),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                ] else if (widget.selectedSourceTypeCode != 'school_past') ...[
                  const SizedBox(height: 6),
                  Text(
                    '학교·연도 폴더는 내신 기출 출처에서만 사용됩니다.',
                    style: TextStyle(
                      color: const Color(0xFF9FB3B3).withValues(alpha: 0.95),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: _buildBody(context),
          ),
        ],
      ),
    );
  }

  Widget _buildDocumentTreePanel() {
    final isSchoolPast = widget.selectedSourceTypeCode == 'school_past';
    return SharedFolderTreePanel(
      title: '추출 문서',
      subtitle: isSchoolPast ? null : '학교·연도 폴더는 내신 기출 출처에서만 사용됩니다.',
      nodes: isSchoolPast
          ? _buildSchoolPastSharedTreeNodes()
          : _buildFlatDocumentSharedTreeNodes(),
      selectedNodeId: widget.selectedDocumentId,
      expandedNodeIds: _sharedExpandedNodeIds(),
      onNodeTap: _handleSharedTreeNodeTap,
      onToggleExpanded: _toggleSharedTreeNode,
      isLoading: widget.isLoading,
      listBottomPadding: 116,
      emptyMessage: '조건에 맞는 추출 문서가 없습니다.',
    );
  }

  Set<String> _sharedExpandedNodeIds() {
    return {
      for (final school in _expandedSchools) 'school:$school',
      for (final yearKey in _expandedYearBuckets) 'year:$yearKey',
    };
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
    if (meta is _ProblemBankTreeNodeMeta && meta.document != null) {
      widget.onDocumentSelected(meta.document!.id);
      return;
    }
    _toggleSharedTreeNode(node);
  }

  void _toggleSharedTreeNode(SharedFolderTreeNode node) {
    final meta = node.data;
    if (meta is! _ProblemBankTreeNodeMeta) return;
    setState(() {
      if (meta.kind == _ProblemBankTreeNodeKind.school) {
        if (_expandedSchools.contains(meta.school)) {
          _expandedSchools.remove(meta.school);
        } else {
          _expandedSchools.add(meta.school);
        }
      } else if (meta.kind == _ProblemBankTreeNodeKind.year) {
        final yearKey = '${meta.school}|${meta.year}';
        if (_expandedYearBuckets.contains(yearKey)) {
          _expandedYearBuckets.remove(yearKey);
        } else {
          _expandedYearBuckets.add(yearKey);
        }
      }
    });
  }

  Widget _buildBody(BuildContext context) {
    if (widget.isLoading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (widget.selectedSourceTypeCode == 'private_material') {
      return _buildPrivateMaterialPageTree();
    }
    if (widget.documents.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            '조건에 맞는 추출 문서가 없습니다.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Color(0xFF9FB3B3),
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
          ),
        ),
      );
    }
    if (widget.selectedSourceTypeCode == 'school_past') {
      return _buildSchoolPastTree(context);
    }
    return _buildFlatList(context);
  }

  Widget _buildPrivateMaterialPageTree() {
    if (widget.privateMaterialUnits.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Text(
            widget.privateMaterialEmptyMessage,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFF9FB3B3),
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
          ),
        ),
      );
    }
    return Listener(
      onPointerUp: (_) => _finishPrivatePageDrag(),
      onPointerCancel: (_) => _cancelPrivatePageDrag(),
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 116),
        itemCount: widget.privateMaterialUnits.length,
        itemBuilder: (context, bigIndex) {
          final big = widget.privateMaterialUnits[bigIndex];
          return Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              initiallyExpanded: bigIndex == 0,
              tilePadding: const EdgeInsets.symmetric(horizontal: 6),
              childrenPadding: const EdgeInsets.only(left: 8, bottom: 6),
              iconColor: const Color(0xFF8AA5A5),
              collapsedIconColor: const Color(0xFF8AA5A5),
              title: Text(
                big.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFFB8C9C9),
                  fontWeight: FontWeight.w800,
                  fontSize: 13.2,
                  height: 1.2,
                ),
              ),
              children: [
                for (final mid in big.mids) _buildPrivateMidNode(mid),
              ],
            ),
          );
        },
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

  Widget _buildPrivateMidNode(ProblemBankPrivateMaterialMidNode mid) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        initiallyExpanded: true,
        tilePadding: const EdgeInsets.only(left: 8, right: 4),
        childrenPadding: const EdgeInsets.only(left: 10, bottom: 4),
        iconColor: const Color(0xFF8AA5A5),
        collapsedIconColor: const Color(0xFF8AA5A5),
        title: Text(
          mid.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Color(0xFFAFC2C2),
            fontWeight: FontWeight.w800,
            fontSize: 12.4,
          ),
        ),
        children: [
          for (final small in mid.smalls) _buildPrivateSmallNode(small),
        ],
      ),
    );
  }

  Widget _buildPrivateSmallNode(ProblemBankPrivateMaterialSmallNode small) {
    final pageKeys = small.pages.map((p) => p.key).toList(growable: false);
    final selected = pageKeys.isNotEmpty &&
        pageKeys.every(widget.selectedPrivateMaterialPageKeys.contains);
    final partiallySelected = !selected &&
        pageKeys.any(widget.selectedPrivateMaterialPageKeys.contains);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: widget.onPrivateMaterialPageKeysToggled == null
                ? null
                : () => widget.onPrivateMaterialPageKeysToggled!(
                      pageKeys,
                      !selected,
                    ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
              child: Row(
                children: [
                  Checkbox(
                    value: selected ? true : (partiallySelected ? null : false),
                    tristate: true,
                    visualDensity: VisualDensity.compact,
                    side: const BorderSide(color: Color(0xFF5E7777)),
                    activeColor: const Color(0xFF1A6B5E),
                    onChanged: widget.onPrivateMaterialPageKeysToggled == null
                        ? null
                        : (v) => widget.onPrivateMaterialPageKeysToggled!(
                              pageKeys,
                              v == true,
                            ),
                  ),
                  Expanded(
                    child: Text(
                      small.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selected
                            ? const Color(0xFFD6ECEA)
                            : const Color(0xFF8FAAAA),
                        fontWeight:
                            selected ? FontWeight.w800 : FontWeight.w700,
                        fontSize: 11.6,
                      ),
                    ),
                  ),
                  Text(
                    '${small.pages.length}쪽',
                    style: const TextStyle(
                      color: Color(0xFF6F8585),
                      fontWeight: FontWeight.w700,
                      fontSize: 10.8,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final page in small.pages) _buildPrivatePageTile(page),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPrivatePageTile(ProblemBankPrivateMaterialPageNode page) {
    final selected = _isEffectivePrivatePageSelected(page.key);
    return MouseRegion(
      onEnter: (_) => _enterPrivatePageDrag(page.key),
      child: Listener(
        onPointerDown: (event) {
          if (event.buttons == kPrimaryMouseButton) {
            _startPrivatePageDrag(page.key);
          }
        },
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: widget.onPrivateMaterialPageToggled == null
              ? null
              : () {
                  if (_privatePageSuppressNextTap) {
                    setState(() => _privatePageSuppressNextTap = false);
                    return;
                  }
                  widget.onPrivateMaterialPageToggled!(page.key, !selected);
                },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(
              children: [
                IgnorePointer(
                  child: Checkbox(
                    value: selected,
                    visualDensity: VisualDensity.compact,
                    side: const BorderSide(color: Color(0xFF5E7777)),
                    activeColor: const Color(0xFF1A6B5E),
                    onChanged: widget.onPrivateMaterialPageToggled == null
                        ? null
                        : (_) {},
                  ),
                ),
                Expanded(
                  child: Text(
                    '${page.displayPage}쪽',
                    style: TextStyle(
                      color: selected
                          ? const Color(0xFFD6ECEA)
                          : const Color(0xFF9FB3B3),
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                      fontSize: 12.2,
                    ),
                  ),
                ),
                Text(
                  '${page.questionCount}문항',
                  style: const TextStyle(
                    color: Color(0xFF6F8585),
                    fontWeight: FontWeight.w700,
                    fontSize: 10.8,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFlatList(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 116),
      itemCount: widget.documents.length,
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        return _buildDocTile(widget.documents[index]);
      },
    );
  }

  Widget _buildSchoolPastTree(BuildContext context) {
    final grouped = _groupBySchoolThenYear(widget.documents);
    final schools = _sortedSchools(grouped.keys);
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 116),
      itemCount: schools.length,
      itemBuilder: (context, si) {
        final school = schools[si];
        final byYear = grouped[school]!;
        final years = _sortedYears(byYear.keys);
        final schoolOpen = _expandedSchools.contains(school);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _sectionHeader(
              title: school,
              expanded: schoolOpen,
              onTap: () {
                setState(() {
                  if (schoolOpen) {
                    _expandedSchools.remove(school);
                  } else {
                    _expandedSchools.add(school);
                  }
                });
              },
            ),
            if (schoolOpen)
              Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final year in years)
                      _buildYearSection(
                        school: school,
                        yearLabel: year,
                        docs: byYear[year]!,
                      ),
                  ],
                ),
              ),
            if (si < schools.length - 1) const SizedBox(height: 4),
          ],
        );
      },
    );
  }

  Widget _buildYearSection({
    required String school,
    required String yearLabel,
    required List<LearningProblemDocumentSummary> docs,
  }) {
    final yearKey = '$school|$yearLabel';
    final yearOpen = _expandedYearBuckets.contains(yearKey);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader(
          title: yearLabel == '미지정' ? '연도 미지정' : '$yearLabel년',
          dense: true,
          expanded: yearOpen,
          onTap: () {
            setState(() {
              if (yearOpen) {
                _expandedYearBuckets.remove(yearKey);
              } else {
                _expandedYearBuckets.add(yearKey);
              }
            });
          },
        ),
        if (yearOpen)
          Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final doc in docs)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: _buildDocTile(doc),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _sectionHeader({
    required String title,
    required bool expanded,
    required VoidCallback onTap,
    bool dense = false,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 8,
            vertical: dense ? 6 : 8,
          ),
          child: Row(
            children: [
              Icon(
                expanded ? Icons.expand_more : Icons.chevron_right,
                size: dense ? 18 : 20,
                color: const Color(0xFF8AA5A5),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFB8C9C9),
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                    height: 1.2,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDocTile(LearningProblemDocumentSummary doc) {
    final selected = doc.id == widget.selectedDocumentId;
    final subtitle = doc.displaySubtitle;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => widget.onDocumentSelected(doc.id),
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? _selectedBg : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? const Color(0xFF2B6B61) : Colors.transparent,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                selected
                    ? Icons.picture_as_pdf_outlined
                    : Icons.description_outlined,
                color: selected
                    ? const Color(0xFFBEE7D2)
                    : const Color(0xFF8AA5A5),
                size: 20,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    doc.displayTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected
                          ? const Color(0xFFD6ECEA)
                          : const Color(0xFF9FB3B3),
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                      fontSize: 13,
                      height: 1.25,
                    ),
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selected
                            ? const Color(0xFF8FB8B5)
                            : const Color(0xFF7A8F8F),
                        fontWeight: FontWeight.w600,
                        fontSize: 11,
                        height: 1.25,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _ProblemBankTreeNodeKind {
  school,
  year,
  document,
}

class _ProblemBankTreeNodeMeta {
  const _ProblemBankTreeNodeMeta._({
    required this.kind,
    this.school = '',
    this.year = '',
    this.document,
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

  final _ProblemBankTreeNodeKind kind;
  final String school;
  final String year;
  final LearningProblemDocumentSummary? document;
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
