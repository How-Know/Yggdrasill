import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';
import '../../services/data_manager.dart';
import '../../widgets/dialog_tokens.dart';
import '../../models/student_flow.dart';

class HomeworkQuickAddProxyDialog extends StatefulWidget {
  final String studentId;
  final String? initialTitle;
  final Color? initialColor;
  final List<StudentFlow> flows;
  final String? initialFlowId;
  const HomeworkQuickAddProxyDialog({
    required this.studentId,
    required this.flows,
    this.initialTitle,
    this.initialColor,
    this.initialFlowId,
  });
  @override
  State<HomeworkQuickAddProxyDialog> createState() => HomeworkQuickAddProxyDialogState();
}

class HomeworkQuickAddProxyDialogState extends State<HomeworkQuickAddProxyDialog> {
  late final TextEditingController _title;
  late final TextEditingController _content;
  late final TextEditingController _page;
  late final TextEditingController _count;
  late Color _color;
  String _type = '프린트';
  late String _flowId;
  bool _loadingFlowTextbooks = false;
  bool _loadingMetadata = false;
  bool _manualPageMode = false;
  List<_LinkedTextbook> _linkedTextbooks = const <_LinkedTextbook>[];
  String? _selectedLinkedBookKey;
  List<_BigUnitSelectionNode> _units = const <_BigUnitSelectionNode>[];

  _LinkedTextbook? get _selectedLinkedBook {
    final key = _selectedLinkedBookKey;
    if (key == null) return null;
    for (final item in _linkedTextbooks) {
      if (item.key == key) return item;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _title = ImeAwareTextEditingController(text: widget.initialTitle ?? '');
    _content = ImeAwareTextEditingController(text: '');
    _page = ImeAwareTextEditingController(text: '');
    _count = ImeAwareTextEditingController(text: '');
    _color = _colorForType(_type);
    final initial = widget.initialFlowId;
    if (initial != null && widget.flows.any((f) => f.id == initial)) {
      _flowId = initial;
    } else {
      _flowId = widget.flows.isNotEmpty ? widget.flows.first.id : '';
    }
    _handleFlowChanged();
  }
  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    _page.dispose();
    _count.dispose();
    super.dispose();
  }

  InputDecoration _inputDecoration(String label, {String? hint}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      labelStyle: const TextStyle(color: kDlgTextSub),
      hintStyle: const TextStyle(color: Color(0xFF6E7E7E)),
      filled: true,
      fillColor: kDlgFieldBg,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: kDlgBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: kDlgAccent, width: 1.4),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    );
  }

  Color _colorForType(String type) {
    switch (type) {
      case '프린트':
        return Colors.blue;
      case '교재':
        return Colors.green;
      case '문제집':
        return Colors.amber;
      case '학습':
        return Colors.purple;
      case '테스트':
        return Colors.red;
      default:
        return Colors.blue;
    }
  }

  String _composeBody() {
    final content = _content.text.trim();
    final page = _page.text.trim();
    final count = _count.text.trim();
    return _composeBodyValues(page: page, count: count, content: content);
  }

  String _composeBodyValues({
    required String page,
    required String count,
    required String content,
  }) {
    final parts = <String>[];
    if (page.isNotEmpty) parts.add('p.$page');
    if (count.isNotEmpty) parts.add('${count}문항');
    if (parts.isEmpty) return content;
    if (content.isEmpty) return parts.join(' / ');
    return '${parts.join(' / ')}\n$content';
  }

  Future<void> _handleFlowChanged() async {
    if (_flowId.isEmpty) {
      if (!mounted) return;
      setState(() {
        _linkedTextbooks = const <_LinkedTextbook>[];
        _selectedLinkedBookKey = null;
        _units = const <_BigUnitSelectionNode>[];
        _manualPageMode = false;
      });
      return;
    }
    setState(() {
      _loadingFlowTextbooks = true;
      _loadingMetadata = false;
      _linkedTextbooks = const <_LinkedTextbook>[];
      _selectedLinkedBookKey = null;
      _units = const <_BigUnitSelectionNode>[];
      _manualPageMode = false;
    });
    try {
      final rows = await DataManager.instance.loadFlowTextbookLinks(_flowId);
      if (!mounted) return;
      final links = <_LinkedTextbook>[];
      for (final row in rows) {
        final bookId = (row['book_id'] as String?)?.trim() ?? '';
        final gradeLabel = (row['grade_label'] as String?)?.trim() ?? '';
        if (bookId.isEmpty || gradeLabel.isEmpty) continue;
        links.add(
          _LinkedTextbook(
            bookId: bookId,
            gradeLabel: gradeLabel,
            bookName: (row['book_name'] as String?)?.trim() ?? '(이름 없음)',
            orderIndex: (row['order_index'] as int?) ?? links.length,
          ),
        );
      }
      links.sort((a, b) {
        if (a.orderIndex != b.orderIndex) return a.orderIndex.compareTo(b.orderIndex);
        return a.label.compareTo(b.label);
      });
      setState(() {
        _linkedTextbooks = links;
        _selectedLinkedBookKey = links.isEmpty ? null : links.first.key;
      });
      if (links.isNotEmpty) {
        await _loadMetadataForSelectedBook();
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _linkedTextbooks = const <_LinkedTextbook>[];
        _selectedLinkedBookKey = null;
        _units = const <_BigUnitSelectionNode>[];
      });
    } finally {
      if (mounted) {
        setState(() => _loadingFlowTextbooks = false);
      }
    }
  }

  Future<void> _loadMetadataForSelectedBook() async {
    final linked = _selectedLinkedBook;
    if (linked == null) {
      if (!mounted) return;
      setState(() => _units = const <_BigUnitSelectionNode>[]);
      return;
    }
    setState(() => _loadingMetadata = true);
    try {
      final row = await DataManager.instance.loadTextbookMetadataPayload(
        bookId: linked.bookId,
        gradeLabel: linked.gradeLabel,
      );
      if (!mounted) return;
      final parsed = _parseSelectionUnits(row?['payload']);
      setState(() => _units = parsed);
    } catch (_) {
      if (!mounted) return;
      setState(() => _units = const <_BigUnitSelectionNode>[]);
    } finally {
      if (mounted) {
        setState(() => _loadingMetadata = false);
      }
    }
  }

  List<_BigUnitSelectionNode> _parseSelectionUnits(dynamic payload) {
    if (payload is! Map) return const <_BigUnitSelectionNode>[];
    final unitsRaw = payload['units'];
    if (unitsRaw is! List) return const <_BigUnitSelectionNode>[];
    final List<Map<String, dynamic>> units = unitsRaw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    units.sort((a, b) => _orderIndex(a['order_index']).compareTo(_orderIndex(b['order_index'])));

    final List<_BigUnitSelectionNode> out = <_BigUnitSelectionNode>[];
    for (final u in units) {
      final bigOrder = _orderIndex(u['order_index']);
      final big = _BigUnitSelectionNode(
        name: (u['name'] as String?)?.trim().isNotEmpty == true
            ? (u['name'] as String).trim()
            : '대단원',
        orderIndex: bigOrder,
      );
      final midsRaw = u['middles'];
      if (midsRaw is List) {
        final mids = midsRaw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        mids.sort((a, b) => _orderIndex(a['order_index']).compareTo(_orderIndex(b['order_index'])));
        for (final m in mids) {
          final midOrder = _orderIndex(m['order_index']);
          final mid = _MidUnitSelectionNode(
            name: (m['name'] as String?)?.trim().isNotEmpty == true
                ? (m['name'] as String).trim()
                : '중단원',
            orderIndex: midOrder,
          );
          final smallsRaw = m['smalls'];
          if (smallsRaw is List) {
            final smalls = smallsRaw
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList();
            smalls.sort((a, b) => _orderIndex(a['order_index']).compareTo(_orderIndex(b['order_index'])));
            for (final s in smalls) {
              final smallOrder = _orderIndex(s['order_index']);
              final start = _toInt(s['start_page']);
              final end = _toInt(s['end_page']);
              final Map<int, int> pageCounts = <int, int>{};
              final countsRaw = s['page_counts'];
              if (countsRaw is Map) {
                countsRaw.forEach((k, v) {
                  final p = _toInt(k);
                  final c = _toInt(v);
                  if (p == null || c == null) return;
                  pageCounts[p] = c;
                });
              }
              mid.smalls.add(
                _SmallUnitSelectionNode(
                  name: (s['name'] as String?)?.trim().isNotEmpty == true
                      ? (s['name'] as String).trim()
                      : '소단원',
                  orderIndex: smallOrder,
                  startPage: start,
                  endPage: end,
                  pageCounts: pageCounts,
                ),
              );
            }
          }
          big.middles.add(mid);
        }
      }
      out.add(big);
    }
    return out;
  }

  int _orderIndex(dynamic value) => _toInt(value) ?? (1 << 30);

  int? _toInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  bool _allSmallSelected(_MidUnitSelectionNode mid) =>
      mid.smalls.isNotEmpty && mid.smalls.every((s) => s.selected);

  bool _allMidSelected(_BigUnitSelectionNode big) =>
      big.middles.isNotEmpty && big.middles.every((m) => _allSmallSelected(m));

  bool _hasAnyExplicitSelection() {
    for (final big in _units) {
      if (big.explicitSelected && big.selected) return true;
      for (final mid in big.middles) {
        if (mid.explicitSelected && mid.selected) return true;
        for (final small in mid.smalls) {
          if (small.explicitSelected && small.selected) return true;
        }
      }
    }
    return false;
  }

  void _toggleBig(_BigUnitSelectionNode big, bool selected) {
    setState(() {
      big.selected = selected;
      big.explicitSelected = selected;
      for (final mid in big.middles) {
        mid.selected = selected;
        mid.explicitSelected = false;
        for (final small in mid.smalls) {
          small.selected = selected;
          small.explicitSelected = false;
        }
      }
    });
  }

  void _toggleMid(_BigUnitSelectionNode big, _MidUnitSelectionNode mid, bool selected) {
    setState(() {
      big.explicitSelected = false;
      mid.selected = selected;
      mid.explicitSelected = selected;
      for (final small in mid.smalls) {
        small.selected = selected;
        small.explicitSelected = false;
      }
      big.selected = _allMidSelected(big);
    });
  }

  void _toggleSmall(
    _BigUnitSelectionNode big,
    _MidUnitSelectionNode mid,
    _SmallUnitSelectionNode small,
    bool selected,
  ) {
    setState(() {
      big.explicitSelected = false;
      mid.explicitSelected = false;
      small.selected = selected;
      small.explicitSelected = selected;
      mid.selected = _allSmallSelected(mid);
      big.selected = _allMidSelected(big);
    });
  }

  List<_SelectedSmallUnit> _selectedSmallUnits() {
    final out = <_SelectedSmallUnit>[];
    for (final big in _units) {
      for (final mid in big.middles) {
        for (final small in mid.smalls) {
          if (!small.selected) continue;
          out.add(
            _SelectedSmallUnit(
              bigName: big.name,
              midName: mid.name,
              smallName: small.name,
              bigOrder: big.orderIndex,
              midOrder: mid.orderIndex,
              smallOrder: small.orderIndex,
              startPage: small.startPage,
              endPage: small.endPage,
              pageCounts: small.pageCounts,
            ),
          );
        }
      }
    }
    return out;
  }

  List<_SelectedSmallUnit> _selectedSmallUnitsForMid(
    _BigUnitSelectionNode big,
    _MidUnitSelectionNode mid,
  ) {
    final out = <_SelectedSmallUnit>[];
    for (final small in mid.smalls) {
      if (!small.selected) continue;
      out.add(
        _SelectedSmallUnit(
          bigName: big.name,
          midName: mid.name,
          smallName: small.name,
          bigOrder: big.orderIndex,
          midOrder: mid.orderIndex,
          smallOrder: small.orderIndex,
          startPage: small.startPage,
          endPage: small.endPage,
          pageCounts: small.pageCounts,
        ),
      );
    }
    return out;
  }

  List<_SelectedSmallUnit> _selectedSmallUnitsForBig(_BigUnitSelectionNode big) {
    final out = <_SelectedSmallUnit>[];
    for (final mid in big.middles) {
      out.addAll(_selectedSmallUnitsForMid(big, mid));
    }
    return out;
  }

  String _mergedPageText(List<_SelectedSmallUnit> selected) {
    final ranges = <String>[];
    final seen = <String>{};
    for (final s in selected) {
      if (s.startPage == null || s.endPage == null) continue;
      if (s.startPage == s.endPage) {
        final value = '${s.startPage}';
        if (seen.add(value)) ranges.add(value);
      } else {
        final value = '${s.startPage}-${s.endPage}';
        if (seen.add(value)) ranges.add(value);
      }
    }
    if (ranges.isEmpty) return '';
    return ranges.join(', ');
  }

  String? _mergedCountText(List<_SelectedSmallUnit> selected) {
    int total = 0;
    bool hasAny = false;
    for (final s in selected) {
      if (s.pageCounts.isEmpty) continue;
      hasAny = true;
      for (final v in s.pageCounts.values) {
        total += v;
      }
    }
    if (!hasAny) return null;
    return total.toString();
  }

  List<_SelectedSmallUnit> _sortedSelectedSmallUnits(List<_SelectedSmallUnit> selected) {
    final list = List<_SelectedSmallUnit>.from(selected);
    list.sort((a, b) {
      if (a.bigOrder != b.bigOrder) return a.bigOrder.compareTo(b.bigOrder);
      if (a.midOrder != b.midOrder) return a.midOrder.compareTo(b.midOrder);
      if (a.smallOrder != b.smallOrder) return a.smallOrder.compareTo(b.smallOrder);
      final byBig = a.bigName.compareTo(b.bigName);
      if (byBig != 0) return byBig;
      final byMid = a.midName.compareTo(b.midName);
      if (byMid != 0) return byMid;
      return a.smallName.compareTo(b.smallName);
    });
    return list;
  }

  String _n(int v) => v >= (1 << 29) ? '-' : '${v + 1}';

  String _prefixBig(_BigUnitSelectionNode big) => _n(big.orderIndex);
  String _prefixMid(_BigUnitSelectionNode big, _MidUnitSelectionNode mid) =>
      '${_n(big.orderIndex)}.${_n(mid.orderIndex)}';
  String _prefixSmall(
    _BigUnitSelectionNode big,
    _MidUnitSelectionNode mid,
    _SmallUnitSelectionNode small,
  ) =>
      '${_n(big.orderIndex)}.${_n(mid.orderIndex)}.(${_n(small.orderIndex)})';

  String _pageTextForSmall(_SmallUnitSelectionNode small) {
    if (small.startPage == null || small.endPage == null) return '';
    if (small.startPage == small.endPage) return '${small.startPage}';
    return '${small.startPage}-${small.endPage}';
  }

  String _countTextForSmall(_SmallUnitSelectionNode small) {
    if (small.pageCounts.isEmpty) return '';
    int sum = 0;
    for (final v in small.pageCounts.values) {
      sum += v;
    }
    return sum.toString();
  }

  int? _pageCountForSmall(_SmallUnitSelectionNode small) {
    if (small.pageCounts.isEmpty) return null;
    int sum = 0;
    for (final v in small.pageCounts.values) {
      sum += v;
    }
    return sum;
  }

  Map<String, dynamic> _unitMappingForSmall(
    _BigUnitSelectionNode big,
    _MidUnitSelectionNode mid,
    _SmallUnitSelectionNode small, {
    required String sourceScope,
  }) {
    return {
      'bigOrder': big.orderIndex,
      'midOrder': mid.orderIndex,
      'smallOrder': small.orderIndex,
      'bigName': big.name,
      'midName': mid.name,
      'smallName': small.name,
      'startPage': small.startPage,
      'endPage': small.endPage,
      'pageCount': _pageCountForSmall(small),
      'weight': 1.0,
      'sourceScope': sourceScope,
    };
  }

  String _bookMetaText(_LinkedTextbook book) {
    final lines = <String>['교재: ${book.bookName}'];
    final grade = book.gradeLabel.trim();
    if (grade.isNotEmpty) {
      lines.add('과정: $grade');
    }
    return lines.join('\n');
  }

  _UnitTask _taskFromSmall(
    _LinkedTextbook book,
    _BigUnitSelectionNode big,
    _MidUnitSelectionNode mid,
    _SmallUnitSelectionNode small,
  ) {
    final path = '${big.name} > ${mid.name} > ${small.name}';
    return _UnitTask(
      title: '${_prefixSmall(big, mid, small)} ${small.name}',
      page: _pageTextForSmall(small),
      count: _countTextForSmall(small),
      content: '${_bookMetaText(book)}\n$path',
      sourceUnitLevel: 'small',
      sourceUnitPath: _prefixSmall(big, mid, small),
      unitMappings: [
        _unitMappingForSmall(
          big,
          mid,
          small,
          sourceScope: 'direct_small',
        ),
      ],
    );
  }

  _UnitTask _taskFromMid(
    _LinkedTextbook book,
    _BigUnitSelectionNode big,
    _MidUnitSelectionNode mid,
    List<_SelectedSmallUnit> smalls,
  ) {
    final sorted = _sortedSelectedSmallUnits(smalls);
    final unitMappings = <Map<String, dynamic>>[];
    for (final small in mid.smalls) {
      if (!small.selected) continue;
      unitMappings.add(
        _unitMappingForSmall(
          big,
          mid,
          small,
          sourceScope: 'expanded_from_mid',
        ),
      );
    }
    return _UnitTask(
      title: '${_prefixMid(big, mid)} ${mid.name}',
      page: _mergedPageText(sorted),
      count: _mergedCountText(sorted) ?? '',
      content: '${_bookMetaText(book)}\n${big.name} > ${mid.name}',
      sourceUnitLevel: 'mid',
      sourceUnitPath: _prefixMid(big, mid),
      unitMappings: unitMappings,
    );
  }

  _UnitTask _taskFromBig(
    _LinkedTextbook book,
    _BigUnitSelectionNode big,
    List<_SelectedSmallUnit> smalls,
  ) {
    final sorted = _sortedSelectedSmallUnits(smalls);
    final unitMappings = <Map<String, dynamic>>[];
    for (final mid in big.middles) {
      for (final small in mid.smalls) {
        if (!small.selected) continue;
        unitMappings.add(
          _unitMappingForSmall(
            big,
            mid,
            small,
            sourceScope: 'expanded_from_big',
          ),
        );
      }
    }
    return _UnitTask(
      title: '${_prefixBig(big)} ${big.name}',
      page: _mergedPageText(sorted),
      count: _mergedCountText(sorted) ?? '',
      content: '${_bookMetaText(book)}\n${big.name}',
      sourceUnitLevel: 'big',
      sourceUnitPath: _prefixBig(big),
      unitMappings: unitMappings,
    );
  }

  List<_UnitTask> _buildUnitTasks(_LinkedTextbook book) {
    final tasks = <_UnitTask>[];
    final bool hasExplicit = _hasAnyExplicitSelection();

    if (hasExplicit) {
      for (final big in _units) {
        if (big.explicitSelected && big.selected) {
          final smalls = _selectedSmallUnitsForBig(big);
          if (smalls.isNotEmpty) {
            tasks.add(_taskFromBig(book, big, smalls));
          }
          continue;
        }

        for (final mid in big.middles) {
          if (mid.explicitSelected && mid.selected) {
            final smalls = _selectedSmallUnitsForMid(big, mid);
            if (smalls.isNotEmpty) {
              tasks.add(_taskFromMid(book, big, mid, smalls));
            }
            continue;
          }

          for (final small in mid.smalls) {
            if (!small.selected || !small.explicitSelected) continue;
            tasks.add(_taskFromSmall(book, big, mid, small));
          }
        }
      }
      return tasks;
    }

    for (final big in _units) {
      for (final mid in big.middles) {
        for (final small in mid.smalls) {
          if (!small.selected) continue;
          tasks.add(_taskFromSmall(book, big, mid, small));
        }
      }
    }
    return tasks;
  }

  Widget _buildLinkedFlowMode() {
    final selectedBook = _selectedLinkedBook;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_loadingFlowTextbooks)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(kDlgTextSub),
              ),
            ),
          )
        else ...[
          const Text(
            '교재 선택',
            style: TextStyle(color: kDlgTextSub, fontSize: 13),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final link in _linkedTextbooks)
                ChoiceChip(
                  label: Text(
                    '${link.bookName} · ${link.gradeLabel}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  selected: _selectedLinkedBookKey == link.key,
                  onSelected: (v) async {
                    if (!v) return;
                    setState(() {
                      _selectedLinkedBookKey = link.key;
                    });
                    await _loadMetadataForSelectedBook();
                  },
                  selectedColor: const Color(0xFF1B6B63),
                  backgroundColor: kDlgFieldBg,
                  labelStyle: const TextStyle(color: kDlgText),
                  side: const BorderSide(color: kDlgBorder),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              ChoiceChip(
                label: const Text('교재 단원 선택'),
                selected: !_manualPageMode,
                onSelected: (v) {
                  if (!v) return;
                  setState(() => _manualPageMode = false);
                },
                selectedColor: const Color(0xFF1B6B63),
                backgroundColor: kDlgFieldBg,
                labelStyle: const TextStyle(color: kDlgText),
                side: const BorderSide(color: kDlgBorder),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('페이지 직접 입력'),
                selected: _manualPageMode,
                onSelected: (v) {
                  if (!v) return;
                  setState(() => _manualPageMode = true);
                },
                selectedColor: const Color(0xFF1B6B63),
                backgroundColor: kDlgFieldBg,
                labelStyle: const TextStyle(color: kDlgText),
                side: const BorderSide(color: kDlgBorder),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_manualPageMode)
            _buildManualPageInputs()
          else
            _buildMetadataTree(selectedBook),
        ],
      ],
    );
  }

  Widget _buildManualPageInputs() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _page,
                keyboardType: TextInputType.text,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9\-~,/ ]')),
                ],
                style: const TextStyle(color: kDlgText, fontWeight: FontWeight.w600),
                decoration: _inputDecoration('페이지', hint: '예: 10-12'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _count,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: const TextStyle(color: kDlgText, fontWeight: FontWeight.w600),
                decoration: _inputDecoration('문항수', hint: '예: 12'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _content,
          minLines: 2,
          maxLines: 4,
          style: const TextStyle(color: kDlgText),
          decoration: _inputDecoration('내용', hint: '필요한 추가 내용을 적어주세요'),
        ),
      ],
    );
  }

  Widget _buildMetadataTree(_LinkedTextbook? selectedBook) {
    if (selectedBook == null) {
      return const Text(
        '연결된 교재를 선택하세요.',
        style: TextStyle(color: kDlgTextSub),
      );
    }
    if (_loadingMetadata) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(kDlgTextSub),
          ),
        ),
      );
    }
    if (_units.isEmpty) {
      return const Text(
        '선택한 교재의 메타데이터가 없습니다.',
        style: TextStyle(color: kDlgTextSub),
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 360),
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final big in _units)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(left: 10),
              maintainState: true,
              title: Row(
                children: [
                  Checkbox(
                    value: big.selected,
                    onChanged: (v) => _toggleBig(big, v ?? false),
                    activeColor: kDlgAccent,
                    side: const BorderSide(color: kDlgBorder),
                  ),
                  Expanded(
                    child: Text(
                      big.name,
                      style: const TextStyle(color: kDlgText, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
              children: [
                for (final mid in big.middles)
                  ExpansionTile(
                    tilePadding: const EdgeInsets.only(left: 4),
                    childrenPadding: const EdgeInsets.only(left: 10),
                    maintainState: true,
                    title: Row(
                      children: [
                        Checkbox(
                          value: mid.selected,
                          onChanged: (v) => _toggleMid(big, mid, v ?? false),
                          activeColor: kDlgAccent,
                          side: const BorderSide(color: kDlgBorder),
                        ),
                        Expanded(
                          child: Text(
                            mid.name,
                            style: const TextStyle(
                              color: kDlgText,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    children: [
                      for (final small in mid.smalls)
                        CheckboxListTile(
                          dense: true,
                          contentPadding: const EdgeInsets.only(left: 8),
                          value: small.selected,
                          onChanged: (v) =>
                              _toggleSmall(big, mid, small, v ?? false),
                          activeColor: kDlgAccent,
                          side: const BorderSide(color: kDlgBorder),
                          title: Text(
                            small.label,
                            style: const TextStyle(color: kDlgTextSub),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
        ],
      ),
    );
  }

  void _submit() {
    if (_flowId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('플로우를 선택하세요.')),
      );
      return;
    }

    final hasLinkedTextbooks = _linkedTextbooks.isNotEmpty;
    if (!hasLinkedTextbooks) {
      final title = _title.text.trim();
      if (title.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('과제명을 입력하세요.')),
        );
        return;
      }
      final countRaw = _count.text.trim();
      Navigator.pop(context, {
        'studentId': widget.studentId,
        'flowId': _flowId,
        'type': _type,
        'title': title,
        'page': _page.text.trim(),
        'count': countRaw,
        'content': _content.text.trim(),
        'body': _composeBody(),
        'color': _color,
      });
      return;
    }

    final selectedBook = _selectedLinkedBook;
    if (selectedBook == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('연결된 교재를 선택하세요.')),
      );
      return;
    }

    String page = '';
    String count = '';
    String content = '';
    String title = '';

    if (_manualPageMode) {
      page = _page.text.trim();
      count = _count.text.trim();
      content = _content.text.trim();
      if (page.isEmpty && content.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('페이지 또는 내용을 입력하세요.')),
        );
        return;
      }
      title = '교재 과제';
      final bookMeta = _bookMetaText(selectedBook);
      content = content.isEmpty
          ? bookMeta
          : '$bookMeta\n$content';
    } else {
      final tasks = _buildUnitTasks(selectedBook);
      if (tasks.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('대/중/소단원을 1개 이상 선택하세요.')),
        );
        return;
      }
      final items = <Map<String, dynamic>>[];
      for (final task in tasks) {
        final body = _composeBodyValues(
          page: task.page,
          count: task.count,
          content: task.content,
        );
        items.add({
          'type': '교재',
          'title': task.title,
          'page': task.page,
          'count': task.count,
          'content': task.content,
          'body': body,
          'color': _colorForType('교재'),
          'bookId': selectedBook.bookId,
          'gradeLabel': selectedBook.gradeLabel,
          'sourceUnitLevel': task.sourceUnitLevel,
          'sourceUnitPath': task.sourceUnitPath,
          'unitMappings': task.unitMappings,
        });
      }
      Navigator.pop(context, {
        'studentId': widget.studentId,
        'flowId': _flowId,
        'items': items,
      });
      return;
    }

    final body = _composeBodyValues(
      page: page,
      count: count,
      content: content,
    );
    Navigator.pop(context, {
      'studentId': widget.studentId,
      'flowId': _flowId,
      'type': '교재',
      'title': title,
      'page': page,
      'count': count,
      'content': content,
      'body': body,
      'color': _colorForType('교재'),
      'bookId': selectedBook.bookId,
      'gradeLabel': selectedBook.gradeLabel,
      'sourceUnitLevel': 'manual',
      'sourceUnitPath': null,
      'unitMappings': const <Map<String, dynamic>>[],
    });
  }

  @override
  Widget build(BuildContext context) {
    final linkedMode = _linkedTextbooks.isNotEmpty || _loadingFlowTextbooks;
    return AlertDialog(
      backgroundColor: kDlgBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('과제 추가', style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900)),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const YggDialogSectionHeader(icon: Icons.task_alt, title: '과제 정보'),
            DropdownButtonFormField<String>(
              value: _flowId.isEmpty ? null : _flowId,
              items: widget.flows
                  .map((f) => DropdownMenuItem(value: f.id, child: Text(f.name)))
                  .toList(),
              onChanged: (v) {
                setState(() {
                  _flowId = v ?? _flowId;
                });
                _handleFlowChanged();
              },
              decoration: _inputDecoration('플로우'),
              dropdownColor: kDlgPanelBg,
              style: const TextStyle(color: kDlgText, fontWeight: FontWeight.w600),
              iconEnabledColor: kDlgTextSub,
            ),
            const SizedBox(height: 12),
            if (linkedMode)
              _buildLinkedFlowMode()
            else ...[
              DropdownButtonFormField<String>(
                value: _type,
                items: const [
                  DropdownMenuItem(value: '프린트', child: Text('프린트')),
                  DropdownMenuItem(value: '교재', child: Text('교재')),
                  DropdownMenuItem(value: '문제집', child: Text('문제집')),
                  DropdownMenuItem(value: '학습', child: Text('학습')),
                  DropdownMenuItem(value: '테스트', child: Text('테스트')),
                ],
                onChanged: (v) => setState(() {
                  _type = v ?? '프린트';
                  _color = _colorForType(_type);
                }),
                decoration: _inputDecoration('과제 유형'),
                dropdownColor: kDlgPanelBg,
                style: const TextStyle(color: kDlgText, fontWeight: FontWeight.w600),
                iconEnabledColor: kDlgTextSub,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _title,
                style: const TextStyle(color: kDlgText, fontWeight: FontWeight.w600),
                decoration: _inputDecoration('과제명', hint: '예: 프린트 1장'),
              ),
              const SizedBox(height: 6),
              const Text(
                '과제명만 입력해도 저장됩니다.',
                style: TextStyle(color: kDlgTextSub, fontSize: 12),
              ),
              const SizedBox(height: 12),
              _buildManualPageInputs(),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _submit,
          style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
          child: const Text('추가'),
        ),
      ],
    );
  }
}

class _LinkedTextbook {
  final String bookId;
  final String gradeLabel;
  final String bookName;
  final int orderIndex;

  const _LinkedTextbook({
    required this.bookId,
    required this.gradeLabel,
    required this.bookName,
    required this.orderIndex,
  });

  String get key => '$bookId|$gradeLabel';
  String get label => '$bookName · $gradeLabel';
}

class _BigUnitSelectionNode {
  final String name;
  final int orderIndex;
  final List<_MidUnitSelectionNode> middles = <_MidUnitSelectionNode>[];
  bool selected = false;
  bool explicitSelected = false;

  _BigUnitSelectionNode({required this.name, required this.orderIndex});
}

class _MidUnitSelectionNode {
  final String name;
  final int orderIndex;
  final List<_SmallUnitSelectionNode> smalls = <_SmallUnitSelectionNode>[];
  bool selected = false;
  bool explicitSelected = false;

  _MidUnitSelectionNode({required this.name, required this.orderIndex});
}

class _SmallUnitSelectionNode {
  final String name;
  final int orderIndex;
  final int? startPage;
  final int? endPage;
  final Map<int, int> pageCounts;
  bool selected = false;
  bool explicitSelected = false;

  _SmallUnitSelectionNode({
    required this.name,
    required this.orderIndex,
    required this.startPage,
    required this.endPage,
    required this.pageCounts,
  });

  String get label {
    if (startPage == null || endPage == null) return name;
    if (startPage == endPage) return '$name ($startPage)';
    return '$name ($startPage-$endPage)';
  }
}

class _SelectedSmallUnit {
  final String bigName;
  final String midName;
  final String smallName;
  final int bigOrder;
  final int midOrder;
  final int smallOrder;
  final int? startPage;
  final int? endPage;
  final Map<int, int> pageCounts;

  const _SelectedSmallUnit({
    required this.bigName,
    required this.midName,
    required this.smallName,
    required this.bigOrder,
    required this.midOrder,
    required this.smallOrder,
    required this.startPage,
    required this.endPage,
    required this.pageCounts,
  });
}

class _UnitTask {
  final String title;
  final String page;
  final String count;
  final String content;
  final String sourceUnitLevel;
  final String sourceUnitPath;
  final List<Map<String, dynamic>> unitMappings;

  const _UnitTask({
    required this.title,
    required this.page,
    required this.count,
    required this.content,
    required this.sourceUnitLevel,
    required this.sourceUnitPath,
    required this.unitMappings,
  });
}

// 이어가기: 제목/색상은 고정 표기, 내용만 입력
class HomeworkContinueDialog extends StatefulWidget {
  final String studentId;
  final String title;
  final Color color;
  const HomeworkContinueDialog({required this.studentId, required this.title, required this.color});
  @override
  State<HomeworkContinueDialog> createState() => _HomeworkContinueDialogState();
}

class _HomeworkContinueDialogState extends State<HomeworkContinueDialog> {
  late final TextEditingController _body;
  @override
  void initState() {
    super.initState();
    _body = ImeAwareTextEditingController(text: '');
  }
  @override
  void dispose() { _body.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: const Text('과제 이어가기', style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(width: 12, height: 12, decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Expanded(child: Text(widget.title, style: const TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w600)))
            ]),
            const SizedBox(height: 10),
            TextField(
              controller: _body,
              minLines: 2,
              maxLines: 4,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(labelText: '내용', labelStyle: TextStyle(color: Colors.white60), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)), focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2)))),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('취소', style: TextStyle(color: Colors.white70))),
        FilledButton(
          onPressed: () {
            Navigator.pop(context, {'studentId': widget.studentId, 'body': _body.text.trim()});
          },
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
          child: const Text('추가'),
        ),
      ],
    );
  }
}


