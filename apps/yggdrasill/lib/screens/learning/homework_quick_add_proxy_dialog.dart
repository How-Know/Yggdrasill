import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/ai_summary.dart';
import '../../services/data_manager.dart';
import '../../services/homework_store.dart';
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
  State<HomeworkQuickAddProxyDialog> createState() =>
      HomeworkQuickAddProxyDialogState();
}

class HomeworkQuickAddProxyDialogState
    extends State<HomeworkQuickAddProxyDialog> {
  static const AnimationStyle _fastTreeExpansionStyle = AnimationStyle(
    duration: Duration(milliseconds: 120),
    reverseDuration: Duration(milliseconds: 90),
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  late final TextEditingController _title;
  late final TextEditingController _content;
  late final TextEditingController _rangeTitle;
  late final TextEditingController _rangeContent;
  late final TextEditingController _page;
  late final TextEditingController _count;
  late final TextEditingController _memo;
  late final TextEditingController _groupTitle;
  late Color _color;
  String _type = '프린트';
  late String _flowId;
  bool _loadingFlowTextbooks = false;
  bool _loadingAllFlowTextbooks = false;
  bool _loadingMetadata = false;
  bool _manualPageMode = false;
  List<_LinkedTextbook> _linkedTextbooks = const <_LinkedTextbook>[];
  List<_LinkedTextbook> _allLinkedTextbooks = const <_LinkedTextbook>[];
  String? _selectedLinkedBookKey;
  List<_BigUnitSelectionNode> _units = const <_BigUnitSelectionNode>[];
  String _rangeAutoPage = '';
  String _rangeAutoCount = '';
  String _rangeAutoScope = '-';
  List<Map<String, dynamic>> _rangeAutoUnitMappings =
      const <Map<String, dynamic>>[];
  bool _rangeAiLoading = false;
  int _rangeAiRequestId = 0;
  String _selectedLinkedTextbookType = '';
  int _selectedSplitParts = 1;
  final List<_DraftGroupItem> _draftGroupItems = <_DraftGroupItem>[];
  int _draftGroupItemSeq = 0;
  String? _expandedBigKey;
  String? _expandedMidKey;

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
    _rangeTitle = ImeAwareTextEditingController(text: '');
    _rangeContent = ImeAwareTextEditingController(text: '');
    _page = ImeAwareTextEditingController(text: '');
    _count = ImeAwareTextEditingController(text: '');
    _memo = ImeAwareTextEditingController(text: '');
    final initialGroupTitle = (widget.initialTitle ?? '').trim();
    _groupTitle = ImeAwareTextEditingController(
      text: initialGroupTitle.isEmpty ? '그룹 과제' : initialGroupTitle,
    );
    _color = _colorForType(_type);
    final initial = widget.initialFlowId;
    if (initial != null && widget.flows.any((f) => f.id == initial)) {
      _flowId = initial;
    } else {
      _flowId = widget.flows.isNotEmpty ? widget.flows.first.id : '';
    }
    unawaited(_loadAllFlowLinkedBooks());
    _handleFlowChanged();
  }

  @override
  void didUpdateWidget(covariant HomeworkQuickAddProxyDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.flows != widget.flows) {
      unawaited(_loadAllFlowLinkedBooks());
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    _rangeTitle.dispose();
    _rangeContent.dispose();
    _page.dispose();
    _count.dispose();
    _memo.dispose();
    _groupTitle.dispose();
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

  String _sanitizeTextbookType(dynamic value) {
    final raw = (value as String?)?.trim() ?? '';
    if (raw == '개념서' || raw == '문제집') return raw;
    return '';
  }

  String _effectiveLinkedHomeworkType() {
    if (_selectedLinkedTextbookType == '문제집') return '문제집';
    final bookName = (_selectedLinkedBook?.bookName ?? '').trim();
    if (bookName.contains('문제집')) return '문제집';
    return '교재';
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

  String _flowNameById(String flowId) {
    for (final flow in widget.flows) {
      if (flow.id == flowId) return flow.name;
    }
    return '';
  }

  List<_LinkedTextbook> _parseFlowLinkedTextbooks({
    required List<dynamic> rows,
    required String flowId,
    required String flowName,
  }) {
    final links = <_LinkedTextbook>[];
    for (final raw in rows) {
      if (raw is! Map) continue;
      final row = Map<String, dynamic>.from(raw);
      final bookId = (row['book_id'] as String?)?.trim() ?? '';
      final gradeLabel = (row['grade_label'] as String?)?.trim() ?? '';
      if (bookId.isEmpty || gradeLabel.isEmpty) continue;
      links.add(
        _LinkedTextbook(
          flowId: flowId,
          flowName: flowName,
          bookId: bookId,
          gradeLabel: gradeLabel,
          bookName: (row['book_name'] as String?)?.trim() ?? '(이름 없음)',
          orderIndex: (row['order_index'] as int?) ?? links.length,
        ),
      );
    }
    links.sort((a, b) {
      if (a.orderIndex != b.orderIndex)
        return a.orderIndex.compareTo(b.orderIndex);
      return a.label.compareTo(b.label);
    });
    return links;
  }

  Future<void> _loadAllFlowLinkedBooks() async {
    if (!mounted) return;
    setState(() => _loadingAllFlowTextbooks = true);
    try {
      final out = <_LinkedTextbook>[];
      for (final flow in widget.flows) {
        final rows = await DataManager.instance.loadFlowTextbookLinks(flow.id);
        out.addAll(
          _parseFlowLinkedTextbooks(
            rows: rows,
            flowId: flow.id,
            flowName: flow.name,
          ),
        );
      }
      if (!mounted) return;
      out.sort((a, b) {
        final byFlow = a.flowName.compareTo(b.flowName);
        if (byFlow != 0) return byFlow;
        if (a.orderIndex != b.orderIndex)
          return a.orderIndex.compareTo(b.orderIndex);
        return a.label.compareTo(b.label);
      });
      setState(() => _allLinkedTextbooks = out);
    } catch (_) {
      if (!mounted) return;
      setState(() => _allLinkedTextbooks = const <_LinkedTextbook>[]);
    } finally {
      if (mounted) {
        setState(() => _loadingAllFlowTextbooks = false);
      }
    }
  }

  Future<void> _handleFlowChanged({
    String? preferredLinkedBookKey,
    bool forceNoBookSelection = false,
  }) async {
    if (_flowId.isEmpty) {
      if (!mounted) return;
      setState(() {
        _linkedTextbooks = const <_LinkedTextbook>[];
        _selectedLinkedBookKey = null;
        _selectedLinkedTextbookType = '';
        _units = const <_BigUnitSelectionNode>[];
        _expandedBigKey = null;
        _expandedMidKey = null;
        _manualPageMode = false;
      });
      _refreshRangeAutoDraft();
      return;
    }
    setState(() {
      _loadingFlowTextbooks = true;
      _loadingMetadata = false;
      _linkedTextbooks = const <_LinkedTextbook>[];
      if (forceNoBookSelection) {
        _selectedLinkedBookKey = null;
      } else if (preferredLinkedBookKey != null) {
        _selectedLinkedBookKey = preferredLinkedBookKey;
      }
      _selectedLinkedTextbookType = '';
      _units = const <_BigUnitSelectionNode>[];
      _expandedBigKey = null;
      _expandedMidKey = null;
      _manualPageMode = false;
    });
    try {
      final rows = await DataManager.instance.loadFlowTextbookLinks(_flowId);
      if (!mounted) return;
      final links = _parseFlowLinkedTextbooks(
        rows: rows,
        flowId: _flowId,
        flowName: _flowNameById(_flowId),
      );
      final preserveKey = preferredLinkedBookKey ?? _selectedLinkedBookKey;
      final hasPreserveKey =
          preserveKey != null && links.any((e) => e.key == preserveKey);
      final nextSelectedKey =
          forceNoBookSelection ? null : (hasPreserveKey ? preserveKey : null);
      setState(() {
        _linkedTextbooks = links;
        _selectedLinkedBookKey = nextSelectedKey;
      });
      if (nextSelectedKey != null) {
        await _loadMetadataForSelectedBook();
      } else {
        if (mounted) {
          setState(() {
            _units = const <_BigUnitSelectionNode>[];
            _selectedLinkedTextbookType = '';
            _expandedBigKey = null;
            _expandedMidKey = null;
          });
        }
        _refreshRangeAutoDraft();
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _linkedTextbooks = const <_LinkedTextbook>[];
        _selectedLinkedBookKey = null;
        _selectedLinkedTextbookType = '';
        _units = const <_BigUnitSelectionNode>[];
        _expandedBigKey = null;
        _expandedMidKey = null;
      });
      _refreshRangeAutoDraft();
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
      setState(() {
        _units = const <_BigUnitSelectionNode>[];
        _selectedLinkedTextbookType = '';
        _expandedBigKey = null;
        _expandedMidKey = null;
      });
      _refreshRangeAutoDraft();
      return;
    }
    setState(() => _loadingMetadata = true);
    try {
      final row = await DataManager.instance.loadTextbookMetadataPayload(
        bookId: linked.bookId,
        gradeLabel: linked.gradeLabel,
      );
      if (!mounted) return;
      final pageOffset = _toInt(row?['page_offset']) ?? 0;
      final parsed = _parseSelectionUnits(
        row?['payload'],
        pageOffset: pageOffset,
      );
      final textbookType = _sanitizeTextbookType(row?['textbook_type']);
      try {
        await HomeworkStore.instance.loadAll();
      } catch (_) {}
      final issuedSummaryBySmallKey = _issuedSmallSummaryByBook(
        bookId: linked.bookId,
        gradeLabel: linked.gradeLabel,
        units: parsed,
      );
      final acknowledgedSmallKeys =
          await _loadAcknowledgedSmallKeysForLinkedBook(linked);
      _applyIssuedLockedState(
        parsed,
        issuedSummaryBySmallKey,
        acknowledgedSmallKeys,
      );
      _applyDraftBlockedStateToUnits(
        parsed,
        usedPages: _draftUsedPages(),
      );
      setState(() {
        _units = parsed;
        _selectedLinkedTextbookType = textbookType;
        _expandedBigKey = null;
        _expandedMidKey = null;
      });
      _refreshRangeAutoDraft();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _units = const <_BigUnitSelectionNode>[];
        _selectedLinkedTextbookType = '';
        _expandedBigKey = null;
        _expandedMidKey = null;
      });
      _refreshRangeAutoDraft();
    } finally {
      if (mounted) {
        setState(() => _loadingMetadata = false);
      }
    }
  }

  int _toDisplayPage(int raw, int pageOffset) {
    final adjusted = raw - pageOffset;
    return adjusted > 0 ? adjusted : raw;
  }

  int? _toDisplayPageNullable(int? raw, int pageOffset) {
    if (raw == null) return null;
    return _toDisplayPage(raw, pageOffset);
  }

  List<_BigUnitSelectionNode> _parseSelectionUnits(
    dynamic payload, {
    int pageOffset = 0,
  }) {
    if (payload is! Map) return const <_BigUnitSelectionNode>[];
    final unitsRaw = payload['units'];
    if (unitsRaw is! List) return const <_BigUnitSelectionNode>[];
    final List<Map<String, dynamic>> units = unitsRaw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    units.sort((a, b) =>
        _orderIndex(a['order_index']).compareTo(_orderIndex(b['order_index'])));

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
        mids.sort((a, b) => _orderIndex(a['order_index'])
            .compareTo(_orderIndex(b['order_index'])));
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
            smalls.sort((a, b) => _orderIndex(a['order_index'])
                .compareTo(_orderIndex(b['order_index'])));
            for (final s in smalls) {
              final smallOrder = _orderIndex(s['order_index']);
              final start = _toDisplayPageNullable(
                _toInt(s['start_page']),
                pageOffset,
              );
              final end = _toDisplayPageNullable(
                _toInt(s['end_page']),
                pageOffset,
              );
              final Map<int, int> pageCounts = <int, int>{};
              final countsRaw = s['page_counts'];
              if (countsRaw is Map) {
                countsRaw.forEach((k, v) {
                  final rawPage = _toInt(k);
                  final c = _toInt(v);
                  if (rawPage == null || c == null) return;
                  final page = _toDisplayPage(rawPage, pageOffset);
                  pageCounts[page] = (pageCounts[page] ?? 0) + c;
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
                  locked: false,
                  draftBlocked: false,
                  finishedAt: null,
                  completedCount: 0,
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

  String _smallKey(int bigOrder, int midOrder, int smallOrder) {
    return '$bigOrder|$midOrder|$smallOrder';
  }

  String _ackPrefsKeyForLinkedBook(_LinkedTextbook linked) {
    final bookKey = '${linked.bookId}|${linked.gradeLabel}';
    return 'flow_textbook_ack_units_v1:${widget.studentId}|${linked.flowId}|$bookKey';
  }

  Future<Set<String>> _loadAcknowledgedSmallKeysForLinkedBook(
    _LinkedTextbook linked,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final values = prefs.getStringList(_ackPrefsKeyForLinkedBook(linked)) ??
          const <String>[];
      return values.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  void _addPageRange(Set<int> pages, int? a, int? b) {
    if (a == null && b == null) return;
    if (a != null && b != null) {
      int start = a;
      int end = b;
      if (start > end) {
        final temp = start;
        start = end;
        end = temp;
      }
      if (end - start > 1600) {
        if (start > 0) pages.add(start);
        if (end > 0) pages.add(end);
        return;
      }
      for (int p = start; p <= end; p++) {
        if (p > 0) pages.add(p);
      }
      return;
    }
    final single = a ?? b;
    if (single != null && single > 0) {
      pages.add(single);
    }
  }

  Set<int> _pagesFromRawPageText(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return <int>{};
    final normalized = trimmed
        .replaceAll(RegExp(r'p\.', caseSensitive: false), '')
        .replaceAll('페이지', '')
        .replaceAll('쪽', '')
        .replaceAll('~', '-')
        .replaceAll('–', '-')
        .replaceAll('—', '-');
    final tokens = normalized
        .split(RegExp(r'[,/\s]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty);
    final pages = <int>{};
    for (final token in tokens) {
      if (token.contains('-')) {
        final parts = token
            .split('-')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
        if (parts.length != 2) continue;
        _addPageRange(pages, _toInt(parts[0]), _toInt(parts[1]));
      } else {
        final value = _toInt(token);
        if (value != null && value > 0) pages.add(value);
      }
    }
    return pages;
  }

  bool _hasPageOverlap(Set<int> a, Set<int> b) {
    if (a.isEmpty || b.isEmpty) return false;
    final small = a.length <= b.length ? a : b;
    final large = identical(small, a) ? b : a;
    for (final p in small) {
      if (large.contains(p)) return true;
    }
    return false;
  }

  String? _currentDraftBookKey() {
    if (_draftGroupItems.isEmpty) return null;
    final firstKey = _draftGroupItems.first.linkedBookKey;
    for (final item in _draftGroupItems) {
      if (item.linkedBookKey != firstKey) return firstKey;
    }
    return firstKey;
  }

  String? _bookIdentity(_LinkedTextbook? linked) {
    if (linked == null) return null;
    return '${linked.bookId}|${linked.gradeLabel}';
  }

  Set<int> _draftUsedPages({String? excludingDraftKey}) {
    final used = <int>{};
    for (final item in _draftGroupItems) {
      if (excludingDraftKey != null && item.key == excludingDraftKey) continue;
      used.addAll(_pagesFromRawPageText(item.page));
    }
    return used;
  }

  String _pagesToCompactText(Set<int> pages) {
    if (pages.isEmpty) return '';
    final sorted = pages.toList(growable: false)..sort();
    final chunks = <String>[];
    int start = sorted.first;
    int prev = sorted.first;
    for (int i = 1; i < sorted.length; i++) {
      final cur = sorted[i];
      if (cur == prev + 1) {
        prev = cur;
        continue;
      }
      chunks.add(start == prev ? '$start' : '$start-$prev');
      start = cur;
      prev = cur;
    }
    chunks.add(start == prev ? '$start' : '$start-$prev');
    return chunks.join(', ');
  }

  Set<int> _smallPages(_SmallUnitSelectionNode small) {
    final pages = <int>{...small.pageCounts.keys};
    _addPageRange(pages, small.startPage, small.endPage);
    return pages;
  }

  void _applyDraftBlockedStateToUnits(
    List<_BigUnitSelectionNode> units, {
    required Set<int> usedPages,
  }) {
    for (final big in units) {
      big.explicitSelected = false;
      for (final mid in big.middles) {
        mid.explicitSelected = false;
        for (final small in mid.smalls) {
          final blockedByDraft = usedPages.isNotEmpty &&
              _hasPageOverlap(_smallPages(small), usedPages);
          small.draftBlocked = blockedByDraft;
          if (small.draftBlocked) {
            small.selected = false;
            small.explicitSelected = false;
          }
        }
        mid.selected = _allSmallSelected(mid);
      }
      big.selected = _allMidSelected(big);
    }
  }

  void _resetRangeSelectionAfterAdd() {
    setState(() {
      for (final big in _units) {
        big.explicitSelected = false;
        for (final mid in big.middles) {
          mid.explicitSelected = false;
          for (final small in mid.smalls) {
            if (small.draftBlocked) continue;
            small.selected = false;
            small.explicitSelected = false;
          }
          mid.selected = _allSmallSelected(mid);
        }
        big.selected = _allMidSelected(big);
      }
    });
    _refreshRangeAutoDraft();
  }

  String _normalizeConceptLabel(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return '';
    text = text.replaceAll(RegExp(r'\s+'), ' ');
    text = text.replaceAll(RegExp(r'^\d+(?:[.\-]\d+)*\s*'), '');
    text = text.replaceAll(RegExp(r'^[\[\(]?\d+[\]\)]\s*'), '');
    text = text.replaceAll(RegExp(r'^(대단원|중단원|소단원)\s*'), '');
    text = text.replaceAll(RegExp(r'\s*(대단원|중단원|소단원)$'), '');
    text = text.replaceAll(RegExp(r'^\W+'), '');
    text = text.replaceAll(RegExp(r'\W+$'), '');
    return text.trim();
  }

  bool _isGenericConceptLabel(String text) {
    final normalized = text.replaceAll(RegExp(r'\s+'), '').trim();
    if (normalized.isEmpty) return true;
    return RegExp(
      r'^(대단원|중단원|소단원|단원|개념|학습|요약|정리|확인문제|문제|문제풀이|복습|테스트|심화|기초)\d*$',
    ).hasMatch(normalized);
  }

  List<String> _conceptKeywordsFromTitle(String title) {
    var text = _normalizeConceptLabel(title);
    if (text.isEmpty) return const <String>[];
    text = text.replaceAll(RegExp(r'^[0-9.\-()\[\]\s]+'), '');
    text = text.replaceAll('제곱인 수', '제곱수');
    text = text.replaceAll('소인수 분해', '소인수분해');
    const removePhrases = <String>[
      '를 이용하여',
      '을 이용하여',
      '를 활용하여',
      '을 활용하여',
      '를 통해',
      '을 통해',
      '에 대하여',
      '에 대해',
      '에 대한',
      '문제풀이',
      '문제를',
      '문제',
      '문항',
      '구하기',
      '풀기',
      '알아보기',
      '이해하기',
      '연습하기',
      '확인하기',
      '정리하기',
      '학습하기',
    ];
    for (final phrase in removePhrases) {
      text = text.replaceAll(phrase, ' ');
    }
    text = text.replaceAll(RegExp(r'\d+'), ' ');
    text = text.replaceAll(RegExp(r'[()\[\]{}]'), ' ');
    text = text
        .replaceAllMapped(
          RegExp(r'([가-힣]{1,})와([가-힣]{1,})'),
          (m) => '${m[1]} ${m[2]}',
        )
        .replaceAllMapped(
          RegExp(r'([가-힣]{1,})과([가-힣]{1,})'),
          (m) => '${m[1]} ${m[2]}',
        );
    text = text.replaceAll(RegExp(r'[,/|·\-]+'), ' ');
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return const <String>[];

    const stopWords = <String>{
      '개념',
      '정리',
      '학습',
      '요약',
      '문제',
      '문항',
      '확인',
      '테스트',
      '연습',
      '복습',
      '단원',
      '수',
    };
    final out = <String>[];
    final seen = <String>{};
    final tokens = text
        .split(RegExp(r'\s+'))
        .map((e) => _normalizeConceptLabel(e))
        .map((e) => e.replaceAll(RegExp(r'^(와|과|및|또는)+'), ''))
        .map((e) => e.replaceAll(RegExp(r'(와|과|및|또는)+$'), ''))
        .map((e) => e.trim())
        .where((e) => e.length >= 2)
        .where((e) => !stopWords.contains(e))
        .where((e) => !_isGenericConceptLabel(e));
    for (final token in tokens) {
      if (seen.add(token)) out.add(token);
    }

    // '소인수'가 있으면 중복 의미인 '인수'는 제외한다.
    if (out.contains('소인수') || out.contains('소인수분해')) {
      out.removeWhere((e) => e == '인수');
    }
    return out;
  }

  String _truncateTitle(String text, int maxChars) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= maxChars) return normalized;
    return normalized.substring(0, maxChars).trimRight();
  }

  String _composeSummaryTitleFromConcepts(
    List<String> conceptKeywords, {
    int maxChars = 20,
  }) {
    final cleaned = <String>[];
    final seen = <String>{};
    for (final raw in conceptKeywords) {
      final keyword = _normalizeConceptLabel(raw);
      if (keyword.isEmpty || _isGenericConceptLabel(keyword)) continue;
      if (seen.add(keyword)) cleaned.add(keyword);
    }
    if (cleaned.isEmpty) return '개념 정리';

    final items = cleaned.take(4).toList(growable: false);
    final candidates = <String>[];
    if (items.isNotEmpty) {
      candidates.add('${items.first} 정리');
    }
    if (items.length >= 2) {
      candidates.add('${items[0]}와 ${items[1]} 정리');
      candidates.add('${items[0]}, ${items[1]} 정리');
    }
    if (items.length >= 3) {
      candidates.add('${items[0]}, ${items[1]}, ${items[2]} 정리');
      candidates.add('${items[0]} · ${items[1]} · ${items[2]} 정리');
    }
    if (items.length >= 4) {
      candidates.add('${items[0]}, ${items[1]} 외 ${items.length - 2}개 개념 정리');
    }

    String best = '';
    for (final candidate in candidates) {
      final normalized = _truncateTitle(candidate, maxChars);
      if (normalized.length > best.length && normalized.length <= maxChars) {
        best = normalized;
      }
    }
    if (best.isNotEmpty && best != '개념 정리') return best;
    return _truncateTitle('${items.first} 정리', maxChars);
  }

  String _fallbackGroupTitle({
    required List<String> conceptKeywords,
    required List<String> itemTitles,
  }) {
    if (conceptKeywords.isNotEmpty) {
      final compact = _composeSummaryTitleFromConcepts(
        conceptKeywords,
        maxChars: 20,
      );
      if (compact.isNotEmpty) return compact;
    }
    if (itemTitles.isNotEmpty) {
      final mergedKeywords = <String>[];
      for (final title in itemTitles) {
        mergedKeywords.addAll(_conceptKeywordsFromTitle(title));
      }
      final compact = _composeSummaryTitleFromConcepts(
        mergedKeywords,
        maxChars: 20,
      );
      if (compact.isNotEmpty) return compact;
    }
    return '개념 정리';
  }

  Future<void> _generateGroupTitleByAi() async {
    if (_draftGroupItems.isEmpty) {
      _setControllerText(_groupTitle, '그룹 과제');
      return;
    }
    final itemTitles = _draftGroupItems
        .map((e) => e.title.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    final conceptKeywords = <String>[];
    final seenConcept = <String>{};
    for (final item in _draftGroupItems) {
      final candidates = _conceptKeywordsFromTitle(item.title);
      for (final keyword in candidates) {
        if (seenConcept.add(keyword)) {
          conceptKeywords.add(keyword);
        }
      }
    }
    final title = _fallbackGroupTitle(
      conceptKeywords: conceptKeywords,
      itemTitles: itemTitles,
    );
    _setControllerText(_groupTitle, _truncateTitle(title, 20));
  }

  bool _isCompletedForIssuedLock(HomeworkItem hw) {
    return hw.status == HomeworkStatus.completed || hw.phase == 4;
  }

  Map<String, _IssuedSmallSummary> _issuedSmallSummaryByBook({
    required String bookId,
    required String gradeLabel,
    required List<_BigUnitSelectionNode> units,
  }) {
    if (bookId.trim().isEmpty || gradeLabel.trim().isEmpty) {
      return <String, _IssuedSmallSummary>{};
    }
    final pagesBySmallKey = <String, Set<int>>{};
    for (final big in units) {
      for (final mid in big.middles) {
        for (final small in mid.smalls) {
          final pages = <int>{...small.pageCounts.keys};
          _addPageRange(pages, small.startPage, small.endPage);
          pagesBySmallKey[
                  _smallKey(big.orderIndex, mid.orderIndex, small.orderIndex)] =
              pages;
        }
      }
    }
    if (pagesBySmallKey.isEmpty) return <String, _IssuedSmallSummary>{};

    final latestFinishedAtBySmallKey = <String, DateTime?>{};
    final completedCountBySmallKey = <String, int>{};
    final items = HomeworkStore.instance.items(widget.studentId);
    for (final hw in items) {
      final hwBookId = (hw.bookId ?? '').trim();
      final hwGrade = (hw.gradeLabel ?? '').trim();
      if (hwBookId != bookId || hwGrade != gradeLabel) continue;
      if (!_isCompletedForIssuedLock(hw)) continue;

      final finishedAt = hw.completedAt ??
          hw.confirmedAt ??
          hw.submittedAt ??
          hw.updatedAt ??
          hw.createdAt;
      final touched = <String>{};

      final mappings = hw.unitMappings;
      if (mappings != null && mappings.isNotEmpty) {
        for (final raw in mappings) {
          final m = Map<String, dynamic>.from(raw);
          final bigOrder = _toInt(m['bigOrder'] ?? m['big_order']);
          final midOrder = _toInt(m['midOrder'] ?? m['mid_order']);
          final smallOrder = _toInt(m['smallOrder'] ?? m['small_order']);
          if (bigOrder == null || midOrder == null || smallOrder == null)
            continue;
          touched.add(_smallKey(bigOrder, midOrder, smallOrder));
        }
      }

      final pages = _pagesFromRawPageText(hw.page ?? '');
      if (pages.isNotEmpty) {
        for (final entry in pagesBySmallKey.entries) {
          if (_hasPageOverlap(pages, entry.value)) {
            touched.add(entry.key);
          }
        }
      }

      for (final key in touched) {
        completedCountBySmallKey[key] =
            (completedCountBySmallKey[key] ?? 0) + 1;
        final prev = latestFinishedAtBySmallKey[key];
        if (prev == null || (finishedAt != null && finishedAt.isAfter(prev))) {
          latestFinishedAtBySmallKey[key] = finishedAt;
        }
      }
    }
    final summary = <String, _IssuedSmallSummary>{};
    final keys = <String>{
      ...completedCountBySmallKey.keys,
      ...latestFinishedAtBySmallKey.keys,
    };
    for (final key in keys) {
      summary[key] = _IssuedSmallSummary(
        latestFinishedAt: latestFinishedAtBySmallKey[key],
        completedCount: completedCountBySmallKey[key] ?? 0,
      );
    }
    return summary;
  }

  void _applyIssuedLockedState(
    List<_BigUnitSelectionNode> units,
    Map<String, _IssuedSmallSummary> issuedSummaryBySmallKey,
    Set<String> acknowledgedSmallKeys,
  ) {
    for (final big in units) {
      big.explicitSelected = false;
      for (final mid in big.middles) {
        mid.explicitSelected = false;
        for (final small in mid.smalls) {
          final key =
              _smallKey(big.orderIndex, mid.orderIndex, small.orderIndex);
          final summary = issuedSummaryBySmallKey[key];
          final locked = acknowledgedSmallKeys.contains(key);
          small.locked = locked;
          small.finishedAt = summary?.latestFinishedAt;
          small.completedCount = summary?.completedCount ?? 0;
          small.selected = false;
          small.explicitSelected = false;
        }
        mid.selected = _allSmallSelected(mid);
      }
      big.selected = _allMidSelected(big);
    }
  }

  bool _hasEditableSmallInMid(_MidUnitSelectionNode mid) =>
      mid.smalls.any((s) => !s.locked && !s.draftBlocked);

  bool _hasEditableSmallInBig(_BigUnitSelectionNode big) =>
      big.middles.any(_hasEditableSmallInMid);

  bool _allSmallSelected(_MidUnitSelectionNode mid) {
    final selectable =
        mid.smalls.where((s) => !s.locked && !s.draftBlocked).toList();
    return selectable.isNotEmpty && selectable.every((s) => s.selected);
  }

  bool _allMidSelected(_BigUnitSelectionNode big) =>
      big.middles.isNotEmpty && big.middles.every((m) => _allSmallSelected(m));

  void _toggleBig(_BigUnitSelectionNode big, bool selected) {
    setState(() {
      big.selected = selected;
      big.explicitSelected = selected;
      for (final mid in big.middles) {
        mid.selected = false;
        mid.explicitSelected = false;
        for (final small in mid.smalls) {
          if (small.locked || small.draftBlocked) continue;
          small.selected = selected;
          small.explicitSelected = false;
        }
        mid.selected = _allSmallSelected(mid);
      }
      big.selected = _allMidSelected(big);
    });
    _refreshRangeAutoDraft();
  }

  void _toggleMid(
      _BigUnitSelectionNode big, _MidUnitSelectionNode mid, bool selected) {
    setState(() {
      big.explicitSelected = false;
      mid.selected = false;
      mid.explicitSelected = selected;
      for (final small in mid.smalls) {
        if (small.locked || small.draftBlocked) continue;
        small.selected = selected;
        small.explicitSelected = false;
      }
      mid.selected = _allSmallSelected(mid);
      big.selected = _allMidSelected(big);
    });
    _refreshRangeAutoDraft();
  }

  void _toggleSmall(
    _BigUnitSelectionNode big,
    _MidUnitSelectionNode mid,
    _SmallUnitSelectionNode small,
    bool selected,
  ) {
    setState(() {
      if (small.locked || small.draftBlocked) return;
      big.explicitSelected = false;
      mid.explicitSelected = false;
      small.selected = selected;
      small.explicitSelected = selected;
      mid.selected = _allSmallSelected(mid);
      big.selected = _allMidSelected(big);
    });
    _refreshRangeAutoDraft();
  }

  List<_SelectedSmallUnit> _selectedSmallUnits() {
    final out = <_SelectedSmallUnit>[];
    for (final big in _units) {
      for (final mid in big.middles) {
        for (final small in mid.smalls) {
          if (!small.selected || small.locked || small.draftBlocked) continue;
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

  List<_SelectedSmallUnit> _sortedSelectedSmallUnits(
      List<_SelectedSmallUnit> selected) {
    final list = List<_SelectedSmallUnit>.from(selected);
    list.sort((a, b) {
      if (a.bigOrder != b.bigOrder) return a.bigOrder.compareTo(b.bigOrder);
      if (a.midOrder != b.midOrder) return a.midOrder.compareTo(b.midOrder);
      if (a.smallOrder != b.smallOrder)
        return a.smallOrder.compareTo(b.smallOrder);
      final byBig = a.bigName.compareTo(b.bigName);
      if (byBig != 0) return byBig;
      final byMid = a.midName.compareTo(b.midName);
      if (byMid != 0) return byMid;
      return a.smallName.compareTo(b.smallName);
    });
    return list;
  }

  String _n(int v) => v >= (1 << 29) ? '-' : '${v + 1}';

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

  String _bookMetaText(_LinkedTextbook book) {
    final lines = <String>['교재: ${book.bookName}'];
    final grade = book.gradeLabel.trim();
    if (grade.isNotEmpty) {
      lines.add('과정: $grade');
    }
    return lines.join('\n');
  }

  void _setControllerText(TextEditingController controller, String text) {
    if (controller.text == text) return;
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  String _prefixFromSelectedSmall(_SelectedSmallUnit small) =>
      '${_n(small.bigOrder)}.${_n(small.midOrder)}.(${_n(small.smallOrder)})';

  String _prefixFromBigOrder(int bigOrder) => _n(bigOrder);

  String _prefixFromMidOrder(int bigOrder, int midOrder) =>
      '${_n(bigOrder)}.${_n(midOrder)}';

  _ExplicitSelectionAutoTitle? _resolveExplicitSelectionAutoTitle() {
    final explicitBigs = <_BigUnitSelectionNode>[];
    final explicitMids =
        <MapEntry<_BigUnitSelectionNode, _MidUnitSelectionNode>>[];

    for (final big in _units) {
      if (big.explicitSelected && big.selected) {
        explicitBigs.add(big);
      }
      for (final mid in big.middles) {
        if (mid.explicitSelected && mid.selected) {
          explicitMids.add(MapEntry(big, mid));
        }
      }
    }

    if (explicitBigs.length == 1 && explicitMids.isEmpty) {
      final big = explicitBigs.first;
      final prefix = _prefixFromBigOrder(big.orderIndex);
      return _ExplicitSelectionAutoTitle(
        title: '$prefix ${big.name}',
        sourceUnitLevel: 'big',
        sourceUnitPath: prefix,
        pathSummary: big.name,
      );
    }

    if (explicitMids.length == 1 && explicitBigs.isEmpty) {
      final ref = explicitMids.first;
      final big = ref.key;
      final mid = ref.value;
      final prefix = _prefixFromMidOrder(big.orderIndex, mid.orderIndex);
      return _ExplicitSelectionAutoTitle(
        title: '$prefix ${mid.name}',
        sourceUnitLevel: 'mid',
        sourceUnitPath: prefix,
        pathSummary: '${big.name} > ${mid.name}',
      );
    }

    return null;
  }

  String _rangeScopeTextFromSelected(List<_SelectedSmallUnit> selected) {
    if (selected.isEmpty) return '-';
    final sorted = _sortedSelectedSmallUnits(selected);
    final firstPrefix = _prefixFromSelectedSmall(sorted.first);
    if (sorted.length == 1) return firstPrefix;
    final lastPrefix = _prefixFromSelectedSmall(sorted.last);
    return '$firstPrefix ~ $lastPrefix (${sorted.length}개)';
  }

  String _aiSummarySourceForSelection(
    _LinkedTextbook book,
    List<_SelectedSmallUnit> selected,
  ) {
    final sorted = _sortedSelectedSmallUnits(selected);
    final b = StringBuffer();
    b.writeln('교재: ${book.bookName}');
    final grade = book.gradeLabel.trim();
    if (grade.isNotEmpty) b.writeln('과정: $grade');
    b.writeln('범위 요약 대상 소단원 수: ${sorted.length}');
    for (final s in sorted.take(14)) {
      final pageText = (s.startPage == null || s.endPage == null)
          ? ''
          : (s.startPage == s.endPage
              ? 'p.${s.startPage}'
              : 'p.${s.startPage}-${s.endPage}');
      final item = '${s.bigName} > ${s.midName} > ${s.smallName}';
      b.writeln(pageText.isEmpty ? item : '$item ($pageText)');
    }
    if (sorted.length > 14) {
      b.writeln('외 ${sorted.length - 14}개');
    }
    return b.toString();
  }

  Future<String> _createAiSummaryLabel(
    _LinkedTextbook book,
    List<_SelectedSmallUnit> selected,
  ) async {
    try {
      final summary = await AiSummaryService.summarize(
        _aiSummarySourceForSelection(book, selected),
        maxChars: 52,
      );
      return summary.trim();
    } catch (_) {
      return '';
    }
  }

  Future<void> _applyAiSummaryForMultiSelection({
    required int requestId,
    required _LinkedTextbook book,
    required List<_SelectedSmallUnit> selected,
  }) async {
    final summary = await _createAiSummaryLabel(book, selected);
    if (!mounted || requestId != _rangeAiRequestId) return;
    final normalized = summary.trim();
    if (normalized.isNotEmpty) {
      final rangeText = _rangeScopeTextFromSelected(selected);
      _setControllerText(_rangeTitle, normalized);
      _setControllerText(
        _rangeContent,
        '${_bookMetaText(book)}\n범위: $rangeText\n요약: $normalized',
      );
    }
    if (mounted && requestId == _rangeAiRequestId) {
      setState(() => _rangeAiLoading = false);
    }
  }

  List<Map<String, dynamic>> _unitMappingsFromSelectedSmalls(
    List<_SelectedSmallUnit> selected,
  ) {
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final s in selected) {
      final key = '${s.bigOrder}|${s.midOrder}|${s.smallOrder}';
      if (!seen.add(key)) continue;
      int? pageCount;
      if (s.pageCounts.isNotEmpty) {
        int sum = 0;
        for (final v in s.pageCounts.values) {
          sum += v;
        }
        pageCount = sum;
      }
      out.add({
        'bigOrder': s.bigOrder,
        'midOrder': s.midOrder,
        'smallOrder': s.smallOrder,
        'bigName': s.bigName,
        'midName': s.midName,
        'smallName': s.smallName,
        'startPage': s.startPage,
        'endPage': s.endPage,
        'pageCount': pageCount,
        'pageCounts': s.pageCounts.isNotEmpty
            ? Map<String, int>.fromEntries(
                s.pageCounts.entries
                    .map((e) => MapEntry(e.key.toString(), e.value)),
              )
            : null,
        'weight': 1.0,
        'sourceScope': 'direct_small',
      });
    }
    return out;
  }

  _UnitTask? _buildMergedRangeTask(_LinkedTextbook book) {
    final selected = _sortedSelectedSmallUnits(_selectedSmallUnits());
    if (selected.isEmpty) return null;
    final first = selected.first;
    final firstPrefix = _prefixFromSelectedSmall(first);
    final explicitAutoTitle = _resolveExplicitSelectionAutoTitle();
    final page = _mergedPageText(selected);
    final count = _mergedCountText(selected) ?? '';
    final title = explicitAutoTitle?.title ??
        (selected.length == 1
            ? '$firstPrefix ${first.smallName}'
            : '교재 과제 (${selected.length}개 소단원)');
    final pathSummary = explicitAutoTitle?.pathSummary ??
        (selected.length == 1
            ? '${first.bigName} > ${first.midName} > ${first.smallName}'
            : '${first.bigName} > ${first.midName} > ${first.smallName} 외 ${selected.length - 1}개');
    final sourceUnitLevel = explicitAutoTitle?.sourceUnitLevel ?? 'merged';
    final sourceUnitPath = explicitAutoTitle?.sourceUnitPath ??
        (selected.length == 1
            ? firstPrefix
            : '$firstPrefix 외 ${selected.length - 1}개');
    final allowAiSummaryTitle =
        explicitAutoTitle == null && selected.length > 1;
    return _UnitTask(
      title: title,
      page: page,
      count: count,
      content: '${_bookMetaText(book)}\n$pathSummary',
      sourceUnitLevel: sourceUnitLevel,
      sourceUnitPath: sourceUnitPath,
      unitMappings: _unitMappingsFromSelectedSmalls(selected),
      allowAiSummaryTitle: allowAiSummaryTitle,
    );
  }

  void _refreshRangeAutoDraft() {
    final requestId = ++_rangeAiRequestId;
    final selectedBook = _selectedLinkedBook;
    if (_manualPageMode || selectedBook == null) {
      if (mounted) {
        setState(() {
          _rangeAutoPage = '';
          _rangeAutoCount = '';
          _rangeAutoScope = '-';
          _rangeAutoUnitMappings = const <Map<String, dynamic>>[];
          _rangeAiLoading = false;
        });
      }
      _setControllerText(_rangeTitle, '');
      _setControllerText(_rangeContent, '');
      return;
    }
    final selected = _sortedSelectedSmallUnits(_selectedSmallUnits());
    if (selected.isEmpty) {
      if (mounted) {
        setState(() {
          _rangeAutoPage = '';
          _rangeAutoCount = '';
          _rangeAutoScope = '-';
          _rangeAutoUnitMappings = const <Map<String, dynamic>>[];
          _rangeAiLoading = false;
        });
      }
      _setControllerText(_rangeTitle, '');
      _setControllerText(_rangeContent, '');
      return;
    }
    final merged = _buildMergedRangeTask(selectedBook);
    if (merged == null) {
      if (mounted) {
        setState(() {
          _rangeAutoPage = '';
          _rangeAutoCount = '';
          _rangeAutoScope = '-';
          _rangeAutoUnitMappings = const <Map<String, dynamic>>[];
          _rangeAiLoading = false;
        });
      }
      _setControllerText(_rangeTitle, '');
      _setControllerText(_rangeContent, '');
      return;
    }
    if (mounted) {
      final shouldRunAiSummary = merged.allowAiSummaryTitle;
      setState(() {
        _rangeAutoPage = merged.page;
        _rangeAutoCount = merged.count;
        _rangeAutoScope = _rangeScopeTextFromSelected(selected);
        _rangeAutoUnitMappings = List<Map<String, dynamic>>.from(
          merged.unitMappings.map((e) => Map<String, dynamic>.from(e)),
        );
        _rangeAiLoading = shouldRunAiSummary;
      });
    }
    _setControllerText(_rangeTitle, merged.title);
    _setControllerText(_rangeContent, merged.content);
    if (merged.allowAiSummaryTitle) {
      unawaited(
        _applyAiSummaryForMultiSelection(
          requestId: requestId,
          book: selectedBook,
          selected: selected,
        ),
      );
    }
  }

  Widget _buildUnlinkedFlowMode() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
        const SizedBox(height: 14),
        _buildManualPageInputs(),
      ],
    );
  }

  Widget _buildPickerChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    final borderColor = selected ? kDlgAccent.withOpacity(0.9) : kDlgBorder;
    final bgColor = selected ? const Color(0x1A33A373) : kDlgFieldBg;
    return Opacity(
      opacity: enabled ? 1.0 : 0.52,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: enabled ? onTap : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(20),
              border:
                  Border.all(color: borderColor, width: selected ? 1.4 : 1.0),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: enabled
                    ? (selected ? kDlgText : kDlgTextSub)
                    : const Color(0xFF7D8B8B),
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                fontSize: 13.8,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTreeCheckbox({
    required bool value,
    required ValueChanged<bool?>? onChanged,
    bool disabled = false,
  }) {
    final isDisabled = disabled || onChanged == null;
    return SizedBox(
      width: 22,
      height: 22,
      child: Checkbox(
        value: value,
        onChanged: onChanged,
        activeColor: isDisabled ? const Color(0xFF3A4448) : kDlgAccent,
        checkColor: isDisabled ? const Color(0xFF9FB3B3) : Colors.white,
        fillColor: MaterialStateProperty.resolveWith((states) {
          if (isDisabled) {
            return value ? const Color(0xFF2F3A3E) : const Color(0xFF1F282C);
          }
          if (states.contains(MaterialState.selected)) return kDlgAccent;
          return null;
        }),
        side: BorderSide(
            color: isDisabled ? const Color(0xFF3A4448) : kDlgBorder),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
      ),
    );
  }

  Widget _buildNoticeCard(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: kDlgPanelBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kDlgBorder),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: kDlgTextSub,
          fontSize: 12.5,
          height: 1.35,
        ),
      ),
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
                style: const TextStyle(
                    color: kDlgText, fontWeight: FontWeight.w600),
                decoration: _inputDecoration('페이지', hint: '예: 10-12'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _count,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: const TextStyle(
                    color: kDlgText, fontWeight: FontWeight.w600),
                decoration: _inputDecoration('문항수', hint: '예: 12'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _memo,
          minLines: 2,
          maxLines: 4,
          style: const TextStyle(color: kDlgText),
          decoration: _inputDecoration('메모', hint: '예: 홀수 번호만 풀기'),
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

  void _showDialogSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  _DraftGroupItem? _buildDraftGroupItemFromInput() {
    final selectedBook = _selectedLinkedBook;
    final useRangeDraft = selectedBook != null && !_manualPageMode;
    final title = useRangeDraft ? _rangeTitle.text.trim() : _title.text.trim();
    if (title.isEmpty) return null;
    final page = useRangeDraft ? _rangeAutoPage.trim() : _page.text.trim();
    final count = useRangeDraft ? _rangeAutoCount.trim() : _count.text.trim();
    final content =
        useRangeDraft ? _rangeContent.text.trim() : _content.text.trim();
    final memo = _memo.text.trim();
    final type = useRangeDraft ? _effectiveLinkedHomeworkType() : _type;
    final color = useRangeDraft ? _colorForType(type) : _color;
    return _DraftGroupItem(
      key: 'draft_${_draftGroupItemSeq++}',
      type: type,
      title: title,
      page: page,
      count: count,
      memo: memo,
      content: content,
      body: _composeBodyValues(page: page, count: count, content: content),
      color: color,
      splitParts: _selectedSplitParts.clamp(1, 4).toInt(),
      linkedBookKey: _bookIdentity(selectedBook),
    );
  }

  void _addDraftGroupItemFromInput() {
    final selectedBook = _selectedLinkedBook;
    final useRangeDraft = selectedBook != null && !_manualPageMode;
    final draftBookKey = _currentDraftBookKey();
    final nextBookKey = _bookIdentity(selectedBook);
    if (_draftGroupItems.isNotEmpty && draftBookKey != nextBookKey) {
      _showDialogSnackBar('그룹 과제는 한 교재 범위에서만 추가할 수 있습니다.');
      return;
    }
    _DraftGroupItem? item = _buildDraftGroupItemFromInput();
    if (item == null) {
      _showDialogSnackBar('과제명을 입력하세요.');
      return;
    }
    final usedPages = _draftUsedPages();
    final incomingPages = _pagesFromRawPageText(item.page);
    if (selectedBook != null && incomingPages.isNotEmpty) {
      if (useRangeDraft && _hasPageOverlap(incomingPages, usedPages)) {
        _showDialogSnackBar('이미 추가된 페이지가 포함되어 있습니다. 범위를 다시 선택하세요.');
        return;
      }
      if (!useRangeDraft) {
        final filteredPages = incomingPages.difference(usedPages);
        if (filteredPages.isEmpty) {
          _showDialogSnackBar('이미 추가된 페이지입니다.');
          return;
        }
        if (filteredPages.length != incomingPages.length) {
          final normalizedPage = _pagesToCompactText(filteredPages);
          item = item.copyWith(
            page: normalizedPage,
            body: _composeBodyValues(
              page: normalizedPage,
              count: item.count,
              content: item.content,
            ),
          );
        }
      }
    }
    final _DraftGroupItem draftItem = item;
    setState(() {
      _draftGroupItems.add(draftItem);
      _applyDraftBlockedStateToUnits(
        _units,
        usedPages: _draftUsedPages(),
      );
    });
    _resetRangeSelectionAfterAdd();
    if (!useRangeDraft) {
      _title.clear();
      _page.clear();
      _count.clear();
      _content.clear();
    }
    _memo.clear();
    unawaited(_generateGroupTitleByAi());
  }

  void _reorderDraftGroupItems(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex -= 1;
      final moved = _draftGroupItems.removeAt(oldIndex);
      _draftGroupItems.insert(newIndex, moved);
    });
  }

  Future<void> _editDraftGroupItem(int index) async {
    if (index < 0 || index >= _draftGroupItems.length) return;
    final source = _draftGroupItems[index];
    final titleController = ImeAwareTextEditingController(text: source.title);
    final pageController = ImeAwareTextEditingController(text: source.page);
    final countController = ImeAwareTextEditingController(text: source.count);
    final memoController = ImeAwareTextEditingController(text: source.memo);
    final contentController =
        ImeAwareTextEditingController(text: source.content);
    var type = source.type;
    var splitParts = source.splitParts;

    final submitted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          return AlertDialog(
            backgroundColor: kDlgBg,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            title: const Text(
              '하위과제 편집',
              style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900),
            ),
            content: SizedBox(
              width: 500,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DropdownButtonFormField<String>(
                      value: type,
                      items: const [
                        DropdownMenuItem(value: '프린트', child: Text('프린트')),
                        DropdownMenuItem(value: '교재', child: Text('교재')),
                        DropdownMenuItem(value: '문제집', child: Text('문제집')),
                        DropdownMenuItem(value: '학습', child: Text('학습')),
                        DropdownMenuItem(value: '테스트', child: Text('테스트')),
                      ],
                      onChanged: (v) => setDialogState(() {
                        type = v ?? '프린트';
                      }),
                      decoration: _inputDecoration('과제 유형'),
                      dropdownColor: kDlgPanelBg,
                      style: const TextStyle(
                        color: kDlgText,
                        fontWeight: FontWeight.w600,
                      ),
                      iconEnabledColor: kDlgTextSub,
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: titleController,
                      style: const TextStyle(
                        color: kDlgText,
                        fontWeight: FontWeight.w600,
                      ),
                      decoration: _inputDecoration('과제명'),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: pageController,
                            keyboardType: TextInputType.text,
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                RegExp(r'[0-9\-~,/ ]'),
                              ),
                            ],
                            style: const TextStyle(
                              color: kDlgText,
                              fontWeight: FontWeight.w600,
                            ),
                            decoration:
                                _inputDecoration('페이지', hint: '예: 10-12'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: countController,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                            style: const TextStyle(
                              color: kDlgText,
                              fontWeight: FontWeight.w600,
                            ),
                            decoration: _inputDecoration('문항수', hint: '예: 12'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: memoController,
                      minLines: 2,
                      maxLines: 4,
                      style: const TextStyle(color: kDlgText),
                      decoration: _inputDecoration('메모'),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<int>(
                      value: splitParts,
                      items: const [
                        DropdownMenuItem<int>(value: 1, child: Text('분할 없음')),
                        DropdownMenuItem<int>(value: 2, child: Text('1/2')),
                        DropdownMenuItem<int>(value: 3, child: Text('1/3')),
                        DropdownMenuItem<int>(value: 4, child: Text('1/4')),
                      ],
                      onChanged: (v) => setDialogState(() {
                        splitParts = (v ?? 1).clamp(1, 4).toInt();
                      }),
                      decoration: _inputDecoration('분할'),
                      dropdownColor: kDlgPanelBg,
                      style: const TextStyle(
                        color: kDlgText,
                        fontWeight: FontWeight.w600,
                      ),
                      iconEnabledColor: kDlgTextSub,
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: contentController,
                      minLines: 2,
                      maxLines: 4,
                      style: const TextStyle(color: kDlgText),
                      decoration: _inputDecoration('내용'),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
                child: const Text('저장'),
              ),
            ],
          );
        },
      ),
    );

    if (submitted != true) return;
    final title = titleController.text.trim();
    if (title.isEmpty) {
      _showDialogSnackBar('과제명을 입력하세요.');
      return;
    }
    final page = pageController.text.trim();
    final count = countController.text.trim();
    final memo = memoController.text.trim();
    final content = contentController.text.trim();
    final updated = source.copyWith(
      type: type,
      title: title,
      page: page,
      count: count,
      memo: memo,
      content: content,
      body: _composeBodyValues(page: page, count: count, content: content),
      color: _colorForType(type),
      splitParts: splitParts.clamp(1, 4).toInt(),
    );
    final otherPages = _draftUsedPages(excludingDraftKey: source.key);
    final updatedPages = _pagesFromRawPageText(updated.page);
    if (updatedPages.isNotEmpty && _hasPageOverlap(updatedPages, otherPages)) {
      _showDialogSnackBar('다른 하위 과제와 페이지가 중복됩니다.');
      return;
    }
    setState(() {
      _draftGroupItems[index] = updated;
      _applyDraftBlockedStateToUnits(
        _units,
        usedPages: _draftUsedPages(),
      );
    });
    _refreshRangeAutoDraft();
    unawaited(_generateGroupTitleByAi());
  }

  Widget _buildFlowSelectorDropdown({required bool enabled}) {
    final selectedValue =
        widget.flows.any((f) => f.id == _flowId) ? _flowId : null;
    return Opacity(
      opacity: enabled ? 1.0 : 0.58,
      child: DropdownButtonFormField<String>(
        value: selectedValue,
        items: widget.flows
            .map(
              (flow) => DropdownMenuItem<String>(
                value: flow.id,
                child: Text(flow.name),
              ),
            )
            .toList(growable: false),
        onChanged: enabled
            ? (v) async {
                if (_draftGroupItems.isNotEmpty) {
                  _showDialogSnackBar('하위 과제가 있을 때는 플로우를 변경할 수 없습니다.');
                  return;
                }
                final nextId = (v ?? '').trim();
                if (nextId.isEmpty || nextId == _flowId) return;
                setState(() {
                  _flowId = nextId;
                  _selectedLinkedBookKey = null;
                  _manualPageMode = false;
                  _units = const <_BigUnitSelectionNode>[];
                });
                await _handleFlowChanged(forceNoBookSelection: true);
              }
            : null,
        decoration: _inputDecoration(enabled ? '플로우 선택' : '플로우 선택 (교재 선택 중)'),
        dropdownColor: kDlgPanelBg,
        style: const TextStyle(color: kDlgText, fontWeight: FontWeight.w600),
        iconEnabledColor: kDlgTextSub,
      ),
    );
  }

  Widget _buildDraftGroupItemList() {
    if (_draftGroupItems.isEmpty) {
      return _buildNoticeCard('하위 과제가 없습니다. 왼쪽에서 입력 후 `과제 추가 버튼`을 눌러주세요.');
    }
    return ReorderableListView.builder(
      buildDefaultDragHandles: false,
      itemCount: _draftGroupItems.length,
      onReorder: _reorderDraftGroupItems,
      itemBuilder: (context, index) {
        final item = _draftGroupItems[index];
        final title = item.title.trim().isEmpty ? '(제목 없음)' : item.title.trim();
        final page = item.page.trim();
        final count = item.count.trim();
        final memo = item.memo.trim();
        final content = item.content.trim();
        return Container(
          key: ValueKey('draft_group_item_${item.key}'),
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
          decoration: BoxDecoration(
            color: kDlgPanelBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: kDlgBorder),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ReorderableDragStartListener(
                index: index,
                child: const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child:
                      Icon(Icons.drag_indicator, color: kDlgTextSub, size: 18),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: const TextStyle(
                              color: kDlgText,
                              fontWeight: FontWeight.w700,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (page.isNotEmpty)
                          Text(
                            'p.$page',
                            style: const TextStyle(
                              color: kDlgTextSub,
                              fontSize: 12.3,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${item.type} · ${count.isEmpty ? '-문항' : '${count}문항'} · 분할 ${item.splitParts == 1 ? '없음' : '1/${item.splitParts}'}',
                      style: const TextStyle(
                        color: kDlgTextSub,
                        fontSize: 12.1,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (memo.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        '메모: $memo',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: kDlgTextSub,
                          fontSize: 12.2,
                          height: 1.25,
                        ),
                      ),
                    ],
                    if (content.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        content,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: kDlgTextSub,
                          fontSize: 12.2,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                tooltip: '편집',
                onPressed: () => _editDraftGroupItem(index),
                icon: const Icon(Icons.edit_outlined,
                    color: kDlgTextSub, size: 19),
              ),
              IconButton(
                tooltip: '삭제',
                onPressed: () {
                  setState(() {
                    _draftGroupItems.removeAt(index);
                    _applyDraftBlockedStateToUnits(
                      _units,
                      usedPages: _draftUsedPages(),
                    );
                  });
                  _refreshRangeAutoDraft();
                  unawaited(_generateGroupTitleByAi());
                },
                icon: const Icon(
                  Icons.delete_outline_rounded,
                  color: Color(0xFFE57373),
                  size: 19,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFlowGroupPanel() {
    final flowName = _flowNameById(_flowId).trim();
    final displayFlow = flowName.isEmpty ? '플로우 미선택' : flowName;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const YggDialogSectionHeader(
          icon: Icons.folder_open_rounded,
          title: '그룹 과제 정보',
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _groupTitle,
          style: const TextStyle(color: kDlgText, fontWeight: FontWeight.w700),
          decoration: _inputDecoration('그룹 제목', hint: '예: 3월 1주차 과제'),
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: kDlgPanelBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: kDlgBorder),
          ),
          child: Text(
            '플로우: $displayFlow  ·  하위 과제 ${_draftGroupItems.length}개',
            style: const TextStyle(
              color: kDlgTextSub,
              fontSize: 12.6,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 12),
        const Divider(height: 1, thickness: 1, color: kDlgBorder),
        const SizedBox(height: 10),
        const YggDialogSectionHeader(
          icon: Icons.list_alt_rounded,
          title: '하위 그룹과제 리스트',
        ),
        const SizedBox(height: 8),
        Expanded(child: _buildDraftGroupItemList()),
      ],
    );
  }

  Widget _buildRangeInlineEditors() {
    final hasSelection = _rangeAutoUnitMappings.isNotEmpty;
    final pageText =
        _rangeAutoPage.trim().isEmpty ? '-' : 'p.${_rangeAutoPage.trim()}';
    final countText =
        _rangeAutoCount.trim().isEmpty ? '-' : '${_rangeAutoCount.trim()}문항';
    final scopeText =
        _rangeAutoScope.trim().isEmpty ? '-' : _rangeAutoScope.trim();
    final flowText =
        _flowNameById(_flowId).trim().isEmpty ? '-' : _flowNameById(_flowId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '플로우: $flowText',
          style: const TextStyle(
            color: kDlgTextSub,
            fontSize: 12.3,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '페이지: $pageText  ·  문항수: $countText',
          style: const TextStyle(
            color: kDlgTextSub,
            fontSize: 12.3,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '범위: $scopeText',
          style: const TextStyle(
            color: kDlgTextSub,
            fontSize: 12.3,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (_rangeAiLoading) ...[
          const SizedBox(height: 4),
          const Text(
            '다중 단원 AI 요약 생성 중...',
            style: TextStyle(
              color: kDlgTextSub,
              fontSize: 11.8,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
        const SizedBox(height: 10),
        TextField(
          controller: _rangeTitle,
          enabled: hasSelection,
          style: const TextStyle(color: kDlgText, fontWeight: FontWeight.w600),
          decoration: _inputDecoration(
            '과제명',
            hint: hasSelection ? '자동 생성된 과제명을 수정할 수 있어요' : '범위를 선택하면 자동 생성됩니다',
          ),
        ),
        const SizedBox(height: 10.4),
        TextField(
          controller: _memo,
          enabled: hasSelection,
          minLines: 2,
          maxLines: 4,
          style: const TextStyle(color: kDlgText),
          decoration: _inputDecoration(
            '메모',
            hint: hasSelection ? '예: 홀수 번호만 풀기' : '범위를 선택하면 입력할 수 있어요',
          ),
        ),
        const SizedBox(height: 10.4),
        TextField(
          controller: _rangeContent,
          enabled: hasSelection,
          minLines: 2,
          maxLines: 4,
          style: const TextStyle(color: kDlgText),
          decoration: _inputDecoration(
            '내용',
            hint: hasSelection ? '자동 생성된 내용을 수정할 수 있어요' : '범위를 선택하면 자동 생성됩니다',
          ),
        ),
      ],
    );
  }

  Widget _buildAssignmentOptions() {
    return Row(
      children: [
        const SizedBox(
          width: 72,
          child: Text(
            '분할',
            style: TextStyle(
              color: kDlgTextSub,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Expanded(
          child: DropdownButtonFormField<int>(
            value: _selectedSplitParts,
            items: const [
              DropdownMenuItem<int>(
                value: 1,
                child: Text('없음'),
              ),
              DropdownMenuItem<int>(
                value: 2,
                child: Text('1/2'),
              ),
              DropdownMenuItem<int>(
                value: 3,
                child: Text('1/3'),
              ),
              DropdownMenuItem<int>(
                value: 4,
                child: Text('1/4'),
              ),
            ],
            onChanged: (v) {
              setState(() {
                _selectedSplitParts = (v ?? 1).clamp(1, 4);
              });
            },
            dropdownColor: kDlgBg,
            style: const TextStyle(
              color: kDlgText,
              fontWeight: FontWeight.w600,
            ),
            decoration: InputDecoration(
              filled: true,
              fillColor: kDlgFieldBg,
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: kDlgBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(
                  color: kDlgAccent,
                  width: 1.4,
                ),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
            iconEnabledColor: kDlgTextSub,
          ),
        ),
      ],
    );
  }

  Widget _buildAddChildButton() {
    return Align(
      alignment: Alignment.centerRight,
      child: FilledButton.icon(
        onPressed: _addDraftGroupItemFromInput,
        style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
        icon: const Icon(Icons.add),
        label: const Text('과제 추가 버튼'),
      ),
    );
  }

  Widget _buildMetadataTree(_LinkedTextbook? selectedBook) {
    if (selectedBook == null) {
      return _buildNoticeCard('연결된 교재를 선택하세요.');
    }
    if (_loadingMetadata) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 22),
        decoration: BoxDecoration(
          color: kDlgPanelBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kDlgBorder),
        ),
        child: const Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(kDlgTextSub),
            ),
          ),
        ),
      );
    }
    if (_units.isEmpty) {
      return _buildNoticeCard('선택한 교재의 메타데이터가 없습니다.');
    }

    return Theme(
      data: Theme.of(context).copyWith(
        dividerColor: Colors.transparent,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final big in _units)
            ExpansionTile(
              key: ValueKey(
                'quickadd_big_${big.orderIndex}_${_expandedBigKey ?? ''}',
              ),
              initiallyExpanded: _expandedBigKey == 'big:${big.orderIndex}',
              onExpansionChanged: (expanded) {
                setState(() {
                  final key = 'big:${big.orderIndex}';
                  if (expanded) {
                    _expandedBigKey = key;
                  } else if (_expandedBigKey == key) {
                    _expandedBigKey = null;
                    _expandedMidKey = null;
                  }
                });
              },
              expansionAnimationStyle: _fastTreeExpansionStyle,
              tilePadding: const EdgeInsets.symmetric(
                horizontal: 2,
                vertical: 2,
              ),
              childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              maintainState: false,
              iconColor: kDlgTextSub,
              collapsedIconColor: kDlgTextSub,
              title: Row(
                children: [
                  _buildTreeCheckbox(
                    value: big.selected,
                    onChanged: _hasEditableSmallInBig(big)
                        ? (v) => _toggleBig(big, v ?? false)
                        : null,
                    disabled: !_hasEditableSmallInBig(big),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      big.name,
                      style: const TextStyle(
                        color: kDlgText,
                        fontWeight: FontWeight.w700,
                        fontSize: 13.5,
                      ),
                    ),
                  ),
                ],
              ),
              children: [
                for (final mid in big.middles)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: ExpansionTile(
                      key: ValueKey(
                        'quickadd_mid_${big.orderIndex}_${mid.orderIndex}_${_expandedMidKey ?? ''}',
                      ),
                      initiallyExpanded: _expandedMidKey ==
                          'big:${big.orderIndex}|mid:${mid.orderIndex}',
                      onExpansionChanged: (expanded) {
                        setState(() {
                          final bigKey = 'big:${big.orderIndex}';
                          final midKey =
                              'big:${big.orderIndex}|mid:${mid.orderIndex}';
                          if (expanded) {
                            _expandedBigKey = bigKey;
                            _expandedMidKey = midKey;
                          } else if (_expandedMidKey == midKey) {
                            _expandedMidKey = null;
                          }
                        });
                      },
                      expansionAnimationStyle: _fastTreeExpansionStyle,
                      tilePadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 1,
                      ),
                      childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      maintainState: false,
                      iconColor: kDlgTextSub,
                      collapsedIconColor: kDlgTextSub,
                      title: Row(
                        children: [
                          _buildTreeCheckbox(
                            value: mid.selected,
                            onChanged: _hasEditableSmallInMid(mid)
                                ? (v) => _toggleMid(big, mid, v ?? false)
                                : null,
                            disabled: !_hasEditableSmallInMid(mid),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              mid.name,
                              style: const TextStyle(
                                color: kDlgText,
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                      children: [
                        for (final small in mid.smalls)
                          Builder(
                            builder: (_) {
                              final page = _pageTextForSmall(small);
                              final count = _countTextForSmall(small);
                              final titleText = page.isEmpty
                                  ? small.name
                                  : '${small.name} (p.$page)';
                              final countText =
                                  count.isEmpty ? '-문항' : '${count}문항';
                              final blocked =
                                  small.locked || small.draftBlocked;
                              final doneText = small.draftBlocked
                                  ? '추가됨'
                                  : (small.locked
                                      ? '완료 인정'
                                      : (small.completedCount > 0
                                          ? '완료 ${small.completedCount}회'
                                          : countText));
                              return Padding(
                                padding: const EdgeInsets.fromLTRB(4, 3, 4, 3),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(8),
                                  mouseCursor: blocked
                                      ? SystemMouseCursors.basic
                                      : SystemMouseCursors.click,
                                  onTap: blocked
                                      ? null
                                      : () => _toggleSmall(
                                            big,
                                            mid,
                                            small,
                                            !small.selected,
                                          ),
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 140),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 7),
                                    decoration: BoxDecoration(
                                      color: blocked
                                          ? const Color(0x1F0F1518)
                                          : (small.selected
                                              ? const Color(0x1A33A373)
                                              : Colors.transparent),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: blocked
                                            ? const Color(0xFF2E3C3F)
                                            : (small.selected
                                                ? kDlgAccent.withOpacity(0.9)
                                                : kDlgBorder.withOpacity(0.8)),
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        _buildTreeCheckbox(
                                          value: small.selected,
                                          onChanged: blocked
                                              ? null
                                              : (v) => _toggleSmall(
                                                    big,
                                                    mid,
                                                    small,
                                                    v ?? false,
                                                  ),
                                          disabled: blocked,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            titleText,
                                            style: TextStyle(
                                              color: blocked
                                                  ? const Color(0xFF6D7777)
                                                  : kDlgTextSub,
                                              fontWeight: FontWeight.w600,
                                              fontSize: 12.5,
                                              height: 1.2,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          doneText,
                                          style: TextStyle(
                                            color: blocked
                                                ? const Color(0xFF6D7777)
                                                : kDlgTextSub,
                                            fontWeight: FontWeight.w700,
                                            fontSize: blocked ? 11.5 : 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                      ],
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _submit({String action = 'add'}) async {
    if (_flowId.isEmpty) {
      _showDialogSnackBar('플로우를 선택하세요.');
      return;
    }

    if (_draftGroupItems.isNotEmpty) {
      final groupTitle =
          _groupTitle.text.trim().isEmpty ? '그룹 과제' : _groupTitle.text.trim();
      Navigator.pop(context, {
        'studentId': widget.studentId,
        'groupMode': true,
        'groupTitle': groupTitle,
        'flowId': _flowId,
        'action': action,
        'items':
            _draftGroupItems.map((e) => e.toJson()).toList(growable: false),
      });
      return;
    }

    final selectedBook = _selectedLinkedBook;
    if (selectedBook == null) {
      _showDialogSnackBar('하위 과제를 1개 이상 추가하세요.');
      return;
    }

    if (_manualPageMode) {
      final linkedType = _effectiveLinkedHomeworkType();
      final page = _page.text.trim();
      final count = _count.text.trim();
      var content = _content.text.trim();
      final inputTitle = _title.text.trim();
      if (page.isEmpty && content.isEmpty) {
        _showDialogSnackBar('페이지 또는 내용을 입력하세요.');
        return;
      }
      final title = inputTitle.isEmpty ? '교재 과제' : inputTitle;
      final bookMeta = _bookMetaText(selectedBook);
      content = content.isEmpty ? bookMeta : '$bookMeta\n$content';
      Navigator.pop(context, {
        'studentId': widget.studentId,
        'flowId': _flowId,
        'action': action,
        'type': linkedType,
        'title': title,
        'page': page,
        'count': count,
        'memo': _memo.text.trim(),
        'content': content,
        'body': _composeBodyValues(
          page: page,
          count: count,
          content: content,
        ),
        'color': _colorForType(linkedType),
        'bookId': selectedBook.bookId,
        'gradeLabel': selectedBook.gradeLabel,
        'sourceUnitLevel': 'manual',
        'sourceUnitPath': null,
        'unitMappings': const <Map<String, dynamic>>[],
        'splitParts': _selectedSplitParts,
      });
      return;
    }

    final mergedTask = _buildMergedRangeTask(selectedBook);
    if (mergedTask == null || mergedTask.unitMappings.isEmpty) {
      _showDialogSnackBar('대/중/소단원을 1개 이상 선택하세요.');
      return;
    }

    final selectedUnits = _sortedSelectedSmallUnits(_selectedSmallUnits());
    final titleRaw = _rangeTitle.text.trim();
    final contentRaw = _rangeContent.text.trim();
    var title = titleRaw.isEmpty ? mergedTask.title : titleRaw;
    var content = contentRaw;
    if (selectedUnits.length > 1 && mergedTask.allowAiSummaryTitle) {
      final aiSummary =
          await _createAiSummaryLabel(selectedBook, selectedUnits);
      if (!mounted) return;
      if (aiSummary.isNotEmpty) {
        final rangeText = _rangeScopeTextFromSelected(selectedUnits);
        if (titleRaw.isEmpty) {
          title = aiSummary;
        }
        if (contentRaw.isEmpty || contentRaw == mergedTask.content) {
          content =
              '${_bookMetaText(selectedBook)}\n범위: $rangeText\n요약: $aiSummary';
        }
      }
    }
    if (title.trim().isEmpty) {
      _showDialogSnackBar('과제명을 입력하세요.');
      return;
    }

    final linkedType = _effectiveLinkedHomeworkType();
    Navigator.pop(context, {
      'studentId': widget.studentId,
      'flowId': _flowId,
      'action': action,
      'type': linkedType,
      'title': title,
      'page': mergedTask.page,
      'count': mergedTask.count,
      'memo': _memo.text.trim(),
      'content': content,
      'body': _composeBodyValues(
        page: mergedTask.page,
        count: mergedTask.count,
        content: content,
      ),
      'color': _colorForType(linkedType),
      'bookId': selectedBook.bookId,
      'gradeLabel': selectedBook.gradeLabel,
      'sourceUnitLevel': mergedTask.sourceUnitLevel,
      'sourceUnitPath': mergedTask.sourceUnitPath,
      'unitMappings': List<Map<String, dynamic>>.from(
        mergedTask.unitMappings.map((e) => Map<String, dynamic>.from(e)),
      ),
      'splitParts': _selectedSplitParts,
    });
  }

  Widget _buildFlowBookPicker() {
    if (_loadingAllFlowTextbooks) {
      return const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation<Color>(kDlgTextSub),
        ),
      );
    }
    if (_allLinkedTextbooks.isEmpty) {
      return _buildNoticeCard('연결된 교재가 없습니다. 플로우 선택 상태로 하위 과제를 추가하세요.');
    }
    final hasDraftItems = _draftGroupItems.isNotEmpty;
    final draftBookKey = _currentDraftBookKey();
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final link in _allLinkedTextbooks)
          (() {
            final linkBookKey = _bookIdentity(link);
            final selected = _selectedLinkedBookKey == link.key;
            final disabledByDraft =
                hasDraftItems && linkBookKey != draftBookKey;
            final enabled = !disabledByDraft;
            return _buildPickerChip(
              label: '${link.bookName} · ${link.gradeLabel}',
              selected: selected,
              enabled: enabled,
              onTap: () async {
                if (_selectedLinkedBookKey == link.key) {
                  if (hasDraftItems) {
                    return;
                  }
                  setState(() {
                    _selectedLinkedBookKey = null;
                    _manualPageMode = false;
                    _units = const <_BigUnitSelectionNode>[];
                  });
                  await _handleFlowChanged(forceNoBookSelection: true);
                  return;
                }
                setState(() {
                  _flowId = link.flowId;
                  _selectedLinkedBookKey = link.key;
                });
                await _handleFlowChanged(
                  preferredLinkedBookKey: link.key,
                );
              },
            );
          })(),
      ],
    );
  }

  Widget _buildRangeSelectionPanel({
    required _LinkedTextbook? selectedBook,
    required bool waitingSelectedBook,
  }) {
    if (waitingSelectedBook) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          YggDialogSectionHeader(
            icon: Icons.account_tree_outlined,
            title: '범위 선택',
          ),
          SizedBox(height: 8),
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(kDlgTextSub),
            ),
          ),
        ],
      );
    }
    if (selectedBook == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const YggDialogSectionHeader(
            icon: Icons.account_tree_outlined,
            title: '범위 선택',
          ),
          const SizedBox(height: 8),
          _buildNoticeCard('교재를 선택하면 단원 범위를 지정할 수 있습니다.'),
        ],
      );
    }

    final body = _manualPageMode
        ? _buildNoticeCard('페이지/문항/내용 입력은 왼쪽 패널에서 설정하세요.')
        : _buildMetadataTree(selectedBook);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const YggDialogSectionHeader(
          icon: Icons.account_tree_outlined,
          title: '범위 선택',
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _buildPickerChip(
              label: '교재 단원 선택',
              selected: !_manualPageMode,
              onTap: () {
                if (!_manualPageMode) return;
                setState(() => _manualPageMode = false);
                _refreshRangeAutoDraft();
              },
            ),
            _buildPickerChip(
              label: '페이지 직접 입력',
              selected: _manualPageMode,
              onTap: () {
                if (_manualPageMode) return;
                setState(() => _manualPageMode = true);
                _refreshRangeAutoDraft();
              },
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: Scrollbar(
            thumbVisibility: !_manualPageMode,
            child: SingleChildScrollView(
              child: body,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRightDetailPanel({
    required bool waitingSelectedBook,
    required _LinkedTextbook? selectedBook,
  }) {
    if (waitingSelectedBook) {
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
    if (selectedBook == null) {
      return _buildUnlinkedFlowMode();
    }
    if (_manualPageMode) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _title,
            style: const TextStyle(
              color: kDlgText,
              fontWeight: FontWeight.w600,
            ),
            decoration: _inputDecoration('과제명', hint: '예: 교재 과제'),
          ),
          const SizedBox(height: 12),
          _buildManualPageInputs(),
        ],
      );
    }
    return _buildRangeInlineEditors();
  }

  @override
  Widget build(BuildContext context) {
    final selectedBook = _selectedLinkedBook;
    final hasBookSelection = _selectedLinkedBookKey != null;
    final showThreeColumn = hasBookSelection;
    final waitingSelectedBook =
        _loadingFlowTextbooks && hasBookSelection && selectedBook == null;
    final double targetDialogWidth = showThreeColumn ? 1420 : 1040;
    final int pickerChipCount = (_allLinkedTextbooks.length + 1).clamp(1, 200);
    final int estimatedPickerRows =
        ((pickerChipCount / (showThreeColumn ? 5 : 4)).ceil().clamp(1, 8))
            .toInt();
    double targetDialogHeight = showThreeColumn ? 780 : 740;
    targetDialogHeight += (estimatedPickerRows - 2) * 24;
    if (_manualPageMode) {
      targetDialogHeight -= 32;
    }
    if (targetDialogHeight < (showThreeColumn ? 720 : 680)) {
      targetDialogHeight = showThreeColumn ? 720 : 680;
    }
    final double maxDialogHeight = MediaQuery.of(context).size.height * 0.9;
    if (targetDialogHeight > maxDialogHeight) {
      targetDialogHeight = maxDialogHeight;
    }
    final Widget inputPanel = Expanded(
      flex: showThreeColumn ? 11 : 12,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const YggDialogSectionHeader(
              icon: Icons.task_alt,
              title: '과제 정보',
            ),
            const SizedBox(height: 8),
            _buildFlowSelectorDropdown(enabled: !hasBookSelection),
            const SizedBox(height: 12),
            _buildFlowBookPicker(),
            const SizedBox(height: 20),
            const Divider(height: 1, thickness: 1, color: kDlgBorder),
            const SizedBox(height: 24),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildRightDetailPanel(
                      waitingSelectedBook: waitingSelectedBook,
                      selectedBook: selectedBook,
                    ),
                    const SizedBox(height: 10),
                    const Divider(height: 1, thickness: 1, color: kDlgBorder),
                    const SizedBox(height: 8),
                    const YggDialogSectionHeader(
                      icon: Icons.tune_rounded,
                      title: '출제 기본 옵션',
                    ),
                    const SizedBox(height: 6),
                    _buildAssignmentOptions(),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            _buildAddChildButton(),
          ],
        ),
      ),
    );
    final Widget groupPanel = Expanded(
      flex: 11,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: kDlgPanelBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kDlgBorder),
        ),
        child: _buildFlowGroupPanel(),
      ),
    );
    final Widget rangePanel = Expanded(
      flex: 10,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: kDlgPanelBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kDlgBorder),
        ),
        child: _buildRangeSelectionPanel(
          selectedBook: selectedBook,
          waitingSelectedBook: waitingSelectedBook,
        ),
      ),
    );
    return AlertDialog(
      backgroundColor: kDlgBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('과제 추가',
          style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900)),
      content: AnimatedContainer(
        duration: const Duration(milliseconds: 130),
        curve: Curves.easeOutQuad,
        width: targetDialogWidth,
        height: targetDialogHeight,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showThreeColumn) ...[
              rangePanel,
              const SizedBox(width: 12),
              inputPanel,
              const SizedBox(width: 12),
              groupPanel,
            ] else ...[
              inputPanel,
              const SizedBox(width: 12),
              groupPanel,
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
        OutlinedButton(
          onPressed: () => _submit(action: 'reserve'),
          style: OutlinedButton.styleFrom(
            foregroundColor: kDlgText,
            side: const BorderSide(color: kDlgBorder),
          ),
          child: const Text('예약'),
        ),
        FilledButton(
          onPressed: () => _submit(action: 'add'),
          style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
          child: const Text('과제 내기'),
        ),
      ],
    );
  }
}

class _DraftGroupItem {
  final String key;
  final String type;
  final String? linkedBookKey;
  final String title;
  final String page;
  final String count;
  final String memo;
  final String content;
  final String body;
  final Color color;
  final int splitParts;

  const _DraftGroupItem({
    required this.key,
    required this.type,
    this.linkedBookKey,
    required this.title,
    required this.page,
    required this.count,
    required this.memo,
    required this.content,
    required this.body,
    required this.color,
    required this.splitParts,
  });

  _DraftGroupItem copyWith({
    String? type,
    String? linkedBookKey,
    String? title,
    String? page,
    String? count,
    String? memo,
    String? content,
    String? body,
    Color? color,
    int? splitParts,
  }) {
    return _DraftGroupItem(
      key: key,
      type: type ?? this.type,
      linkedBookKey: linkedBookKey ?? this.linkedBookKey,
      title: title ?? this.title,
      page: page ?? this.page,
      count: count ?? this.count,
      memo: memo ?? this.memo,
      content: content ?? this.content,
      body: body ?? this.body,
      color: color ?? this.color,
      splitParts: splitParts ?? this.splitParts,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'type': type,
      'title': title,
      'page': page,
      'count': count,
      'memo': memo,
      'content': content,
      'body': body,
      'color': color,
      'splitParts': splitParts.clamp(1, 4).toInt(),
    };
  }
}

class _LinkedTextbook {
  final String flowId;
  final String flowName;
  final String bookId;
  final String gradeLabel;
  final String bookName;
  final int orderIndex;

  const _LinkedTextbook({
    required this.flowId,
    required this.flowName,
    required this.bookId,
    required this.gradeLabel,
    required this.bookName,
    required this.orderIndex,
  });

  String get key => '$flowId|$bookId|$gradeLabel';
  String get label => '$bookName · $gradeLabel';
}

class _IssuedSmallSummary {
  final DateTime? latestFinishedAt;
  final int completedCount;

  const _IssuedSmallSummary({
    required this.latestFinishedAt,
    required this.completedCount,
  });
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
  bool locked;
  bool draftBlocked;
  DateTime? finishedAt;
  int completedCount;
  bool selected = false;
  bool explicitSelected = false;

  _SmallUnitSelectionNode({
    required this.name,
    required this.orderIndex,
    required this.startPage,
    required this.endPage,
    required this.pageCounts,
    this.locked = false,
    this.draftBlocked = false,
    this.finishedAt,
    this.completedCount = 0,
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
  final bool allowAiSummaryTitle;

  const _UnitTask({
    required this.title,
    required this.page,
    required this.count,
    required this.content,
    required this.sourceUnitLevel,
    required this.sourceUnitPath,
    required this.unitMappings,
    required this.allowAiSummaryTitle,
  });
}

class _ExplicitSelectionAutoTitle {
  final String title;
  final String sourceUnitLevel;
  final String sourceUnitPath;
  final String pathSummary;

  const _ExplicitSelectionAutoTitle({
    required this.title,
    required this.sourceUnitLevel,
    required this.sourceUnitPath,
    required this.pathSummary,
  });
}

// 이어가기: 제목/색상은 고정 표기, 내용만 입력
class HomeworkContinueDialog extends StatefulWidget {
  final String studentId;
  final String title;
  final Color color;
  const HomeworkContinueDialog(
      {required this.studentId, required this.title, required this.color});
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
  void dispose() {
    _body.dispose();
    super.dispose();
  }

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
              Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                      color: widget.color, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(widget.title,
                      style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 15,
                          fontWeight: FontWeight.w600)))
            ]),
            const SizedBox(height: 10),
            TextField(
              controller: _body,
              minLines: 2,
              maxLines: 4,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                  labelText: '내용',
                  labelStyle: TextStyle(color: Colors.white60),
                  enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.white24)),
                  focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Color(0xFF1976D2)))),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('취소', style: TextStyle(color: Colors.white70))),
        FilledButton(
          onPressed: () {
            Navigator.pop(context,
                {'studentId': widget.studentId, 'body': _body.text.trim()});
          },
          style:
              FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
          child: const Text('추가'),
        ),
      ],
    );
  }
}
