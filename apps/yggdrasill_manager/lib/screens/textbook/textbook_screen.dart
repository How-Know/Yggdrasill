import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:path/path.dart' as p;

const double _treeIndentStep = 18.0;
const double _treeConnectorWidth = 12.0;
const double _treeLineWidth = 1.4;
const double _treeCornerRadius = 8.0;
const double _treeRowHeight = 38.0;
const Color _treeLineColor = Color(0xFF2A2A2A);
const Color _rsBg = Color(0xFF0B1112);
const Color _rsPanelBg = Color(0xFF10171A);
const Color _rsFieldBg = Color(0xFF15171C);
const Color _rsBorder = Color(0xFF223131);
const Color _rsText = Color(0xFFEAF2F2);
const Color _rsTextSub = Color(0xFF9FB3B3);
const Color _rsAccent = Color(0xFF33A373);

class TextbookScreen extends StatefulWidget {
  const TextbookScreen({super.key});

  @override
  State<TextbookScreen> createState() => _TextbookScreenState();
}

class _TextbookScreenState extends State<TextbookScreen> {
  final _supabase = Supabase.instance.client;

  bool _isLoadingBooks = false;
  bool _isLoadingPdfs = false;
  bool _isSaving = false;

  List<_BookEntry> _books = [];
  String? _selectedBookId;

  List<_PdfEntry> _allPdfs = [];
  List<_PdfEntry> _bodyPdfs = [];
  List<_PdfEntry> _solPdfs = [];
  List<_PdfEntry> _ansPdfs = [];
  String? _selectedBodyKey;
  final List<_BigUnitNode> _bigUnits = [];
  final TextEditingController _pageOffsetCtrl = TextEditingController();
  final Map<String, int> _pageOffsetByKey = {};

  Map<String, int> _gradeOrderByLabel = {};
  int _pdfRequestId = 0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _clearChapterTree();
    _pageOffsetCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    await Future.wait([
      _loadGradeOrders(),
      _loadBooks(),
    ]);
  }

  Future<void> _loadGradeOrders() async {
    try {
      final data = await _supabase
          .from('answer_key_grades')
          .select('label,order_index')
          .order('order_index');
      final rows = (data as List).cast<Map<String, dynamic>>();
      final map = <String, int>{};
      for (final r in rows) {
        final label = (r['label'] as String?)?.trim() ?? '';
        if (label.isEmpty) continue;
        map.putIfAbsent(label, () => (r['order_index'] as int?) ?? map.length);
      }
      if (!mounted) return;
      setState(() {
        _gradeOrderByLabel = map;
        if (_allPdfs.isNotEmpty) {
          _setPdfLists(_allPdfs);
        }
      });
    } catch (e) {
      if (!mounted) return;
      _showError('과정 목록 로드 실패: $e');
    }
  }

  Future<void> _loadBooks() async {
    setState(() => _isLoadingBooks = true);
    try {
      final data = await _supabase
          .from('resource_files')
          .select('id,name,category,order_index,academy_id')
          .order('order_index')
          .order('name');
      final rows = (data as List).cast<Map<String, dynamic>>();
      final books = rows
          .where((r) => r['category'] == null)
          .map((r) => _BookEntry(
                id: r['id'] as String,
                academyId: r['academy_id'] as String?,
                name: (r['name'] as String?)?.trim() ?? '(이름 없음)',
                orderIndex: (r['order_index'] as int?),
              ))
          .toList();
      books.sort((a, b) {
        final ai = a.orderIndex ?? 1 << 30;
        final bi = b.orderIndex ?? 1 << 30;
        final t = ai.compareTo(bi);
        if (t != 0) return t;
        return a.name.compareTo(b.name);
      });
      final selected =
          books.any((b) => b.id == _selectedBookId) ? _selectedBookId : null;
      if (!mounted) return;
      setState(() {
        _books = books;
        _selectedBookId = selected;
        _isLoadingBooks = false;
        if (_selectedBookId == null) {
          _allPdfs = [];
          _bodyPdfs = [];
          _solPdfs = [];
          _ansPdfs = [];
          _selectedBodyKey = null;
          _clearChapterTree();
          _setPageOffsetForSelection();
        }
      });
      if (selected != null) {
        await _loadPdfsForBook(selected);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingBooks = false);
      _showError('교재 목록 로드 실패: $e');
    }
  }

  Future<void> _loadPdfsForBook(String bookId) async {
    final requestId = ++_pdfRequestId;
    setState(() {
      _isLoadingPdfs = true;
      _allPdfs = [];
      _bodyPdfs = [];
      _solPdfs = [];
      _ansPdfs = [];
      _selectedBodyKey = null;
    });
    try {
      final data = await _supabase
          .from('resource_file_links')
          .select('grade,url')
          .eq('file_id', bookId);
      if (!mounted || requestId != _pdfRequestId) return;
      final rows = (data as List).cast<Map<String, dynamic>>();
      final parsed = _parsePdfEntries(rows);
      setState(() {
        _setPdfLists(parsed);
        _isLoadingPdfs = false;
      });
    } catch (e) {
      if (!mounted || requestId != _pdfRequestId) return;
      setState(() => _isLoadingPdfs = false);
      _showError('PDF 목록 로드 실패: $e');
    }
  }

  List<_PdfEntry> _parsePdfEntries(List<Map<String, dynamic>> rows) {
    const allowedKinds = {'body', 'ans', 'sol'};
    final out = <_PdfEntry>[];
    for (final r in rows) {
      final rawGrade = (r['grade'] as String?)?.trim() ?? '';
      final url = (r['url'] as String?)?.trim() ?? '';
      if (rawGrade.isEmpty || url.isEmpty) continue;
      if (!_isPdfUrl(url)) continue;
      final parts = rawGrade.split('#');
      final gradeLabel = parts.isNotEmpty ? parts.first.trim() : '';
      final kind = (parts.length > 1 ? parts[1] : 'body').trim().toLowerCase();
      if (gradeLabel.isEmpty || !allowedKinds.contains(kind)) continue;
      final kindLabel = _kindLabel(kind);
      final fileName = _fileNameFromUrl(url);
      out.add(_PdfEntry(
        key: '$gradeLabel#$kind|$url',
        gradeLabel: gradeLabel,
        kind: kind,
        kindLabel: kindLabel,
        url: url,
        fileName: fileName,
      ));
    }
    return out;
  }

  void _setPdfLists(List<_PdfEntry> all) {
    final sorted = _sortPdfs(List<_PdfEntry>.from(all));
    _allPdfs = sorted;
    _bodyPdfs = sorted.where((e) => e.kind == 'body').toList();
    _solPdfs = sorted.where((e) => e.kind == 'sol').toList();
    _ansPdfs = sorted.where((e) => e.kind == 'ans').toList();
    if (_selectedBodyKey != null &&
        _bodyPdfs.any((e) => e.key == _selectedBodyKey)) {
      _setPageOffsetForSelection();
      return;
    }
    _selectedBodyKey = _bodyPdfs.isEmpty ? null : _bodyPdfs.first.key;
    _setPageOffsetForSelection();
  }

  List<_PdfEntry> _sortPdfs(List<_PdfEntry> entries) {
    entries.sort((a, b) {
      final ai = _gradeOrderByLabel[a.gradeLabel] ?? 1 << 30;
      final bi = _gradeOrderByLabel[b.gradeLabel] ?? 1 << 30;
      final t = ai.compareTo(bi);
      if (t != 0) return t;
      final gradeCmp = a.gradeLabel.compareTo(b.gradeLabel);
      if (gradeCmp != 0) return gradeCmp;
      final kindCmp = _kindOrder(a.kind).compareTo(_kindOrder(b.kind));
      if (kindCmp != 0) return kindCmp;
      return a.fileName.compareTo(b.fileName);
    });
    return entries;
  }

  int _kindOrder(String kind) {
    switch (kind) {
      case 'body':
        return 0;
      case 'sol':
        return 1;
      case 'ans':
        return 2;
      default:
        return 3;
    }
  }

  String _kindLabel(String kind) {
    switch (kind) {
      case 'body':
        return '본문';
      case 'ans':
        return '정답';
      case 'sol':
        return '해설';
      default:
        return kind;
    }
  }

  bool _isPdfUrl(String url) {
    return url.toLowerCase().contains('.pdf');
  }

  String _fileNameFromUrl(String url) {
    final name = p.basename(url);
    return name.isEmpty ? url : name;
  }

  _BookEntry? get _selectedBook {
    if (_selectedBookId == null) return null;
    return _books.firstWhere(
      (b) => b.id == _selectedBookId,
      orElse: () => _BookEntry(id: _selectedBookId!, name: '-', orderIndex: null),
    );
  }

  _PdfEntry? get _selectedBody {
    if (_selectedBodyKey == null) return null;
    return _bodyPdfs.firstWhere(
      (p) => p.key == _selectedBodyKey,
      orElse: () => _PdfEntry(
        key: _selectedBodyKey!,
        gradeLabel: '-',
        kind: 'body',
        kindLabel: '-',
        url: '',
        fileName: '-',
      ),
    );
  }

  _PdfEntry? get _linkedSol {
    final body = _selectedBody;
    if (body == null) return null;
    return _solPdfs.firstWhere(
      (e) => e.gradeLabel == body.gradeLabel,
      orElse: () => _PdfEntry(
        key: '${body.gradeLabel}#sol',
        gradeLabel: body.gradeLabel,
        kind: 'sol',
        kindLabel: '해설',
        url: '',
        fileName: '-',
      ),
    );
  }

  _PdfEntry? get _linkedAns {
    final body = _selectedBody;
    if (body == null) return null;
    return _ansPdfs.firstWhere(
      (e) => e.gradeLabel == body.gradeLabel,
      orElse: () => _PdfEntry(
        key: '${body.gradeLabel}#ans',
        gradeLabel: body.gradeLabel,
        kind: 'ans',
        kindLabel: '정답',
        url: '',
        fileName: '-',
      ),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFFD32F2F),
      ),
    );
  }

  String _pageOffsetKey(String bookId, String gradeLabel) => '$bookId|$gradeLabel';

  void _setPageOffsetForSelection() {
    final bookId = _selectedBookId;
    final gradeLabel = _selectedBody?.gradeLabel;
    if (bookId == null || gradeLabel == null || gradeLabel.isEmpty) {
      _pageOffsetCtrl.text = '';
      return;
    }
    final key = _pageOffsetKey(bookId, gradeLabel);
    final value = _pageOffsetByKey[key];
    _pageOffsetCtrl.text = value?.toString() ?? '';
  }

  void _clearChapterTree() {
    for (final unit in _bigUnits) {
      unit.dispose();
    }
    _bigUnits.clear();
  }

  void _addBigUnit() {
    setState(() => _bigUnits.add(_BigUnitNode()));
  }

  void _addMidUnit(_BigUnitNode parent) {
    setState(() => parent.middles.add(_MidUnitNode()));
  }

  void _addSmallUnit(_MidUnitNode parent) {
    setState(() => parent.smalls.add(_SmallUnitNode()));
  }

  void _removeBigUnit(_BigUnitNode unit) {
    setState(() {
      unit.dispose();
      _bigUnits.remove(unit);
    });
  }

  void _removeMidUnit(_BigUnitNode parent, _MidUnitNode unit) {
    setState(() {
      unit.dispose();
      parent.middles.remove(unit);
    });
  }

  void _removeSmallUnit(_MidUnitNode parent, _SmallUnitNode unit) {
    setState(() {
      unit.dispose();
      parent.smalls.remove(unit);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1F1F1F),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '교재',
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '책과 본문을 선택하면 해설/정답이 자동으로 연결됩니다.',
            style: TextStyle(color: Color(0xFFB3B3B3), fontSize: 14),
          ),
          const SizedBox(height: 20),
          _buildToolbarCard(),
          const SizedBox(height: 16),
          Expanded(
            child: ListView(
              children: [
                _buildSelectionCard(),
                const SizedBox(height: 16),
                _buildChapterTreeCard(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbarCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF18181A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isNarrow = constraints.maxWidth < 900;
          final filters = Wrap(
            spacing: 16,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _buildLabeledControl('책', _buildBookDropdown()),
              _buildLabeledControl('본문', _buildBodyDropdown()),
              _buildLabeledControl('페이지 보정', _buildPageOffsetField()),
            ],
          );
          final actions = _buildSaveButton();
          if (isNarrow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                filters,
                const SizedBox(height: 12),
                actions,
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: filters),
              const SizedBox(width: 12),
              actions,
            ],
          );
        },
      ),
    );
  }

  Widget _buildLabeledControl(String label, Widget control) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(color: Color(0xFFB3B3B3), fontSize: 14)),
        const SizedBox(width: 12),
        control,
      ],
    );
  }

  Widget _buildBookDropdown() {
    if (_isLoadingBooks) {
      return _buildStatusField(
        child: Row(
          children: const [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
            ),
            SizedBox(width: 8),
            Text('교재 불러오는 중...', style: TextStyle(color: Colors.white70, fontSize: 14)),
          ],
        ),
      );
    }
    if (_books.isEmpty) {
      return _buildStatusField(
        child: Row(
          children: const [
            Icon(Icons.menu_book_outlined, color: Colors.white54, size: 18),
            SizedBox(width: 8),
            Text('등록된 교재가 없습니다', style: TextStyle(color: Colors.white54, fontSize: 14)),
          ],
        ),
      );
    }
    return _buildDropdownField(
      value: _selectedBookId,
      hint: '교재 선택',
      items: _books
          .map((b) => DropdownMenuItem(
                value: b.id,
                child: Text(b.name, overflow: TextOverflow.ellipsis),
              ))
          .toList(),
      onChanged: (value) {
        setState(() {
          _selectedBookId = value;
          _allPdfs = [];
          _bodyPdfs = [];
          _solPdfs = [];
          _ansPdfs = [];
          _selectedBodyKey = null;
          _clearChapterTree();
          _setPageOffsetForSelection();
        });
        if (value != null) {
          _loadPdfsForBook(value);
        }
      },
    );
  }

  Widget _buildBodyDropdown() {
    if (_selectedBookId == null) {
      return _buildStatusField(
        child: Row(
          children: const [
            Icon(Icons.picture_as_pdf_outlined, color: Colors.white54, size: 18),
            SizedBox(width: 8),
            Text('책을 먼저 선택하세요', style: TextStyle(color: Colors.white54, fontSize: 14)),
          ],
        ),
      );
    }
    if (_isLoadingPdfs) {
      return _buildStatusField(
        child: Row(
          children: const [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
            ),
            SizedBox(width: 8),
            Text('PDF 불러오는 중...', style: TextStyle(color: Colors.white70, fontSize: 14)),
          ],
        ),
      );
    }
    if (_bodyPdfs.isEmpty) {
      return _buildStatusField(
        child: Row(
          children: const [
            Icon(Icons.picture_as_pdf_outlined, color: Colors.white54, size: 18),
            SizedBox(width: 8),
            Text('본문 PDF가 없습니다', style: TextStyle(color: Colors.white54, fontSize: 14)),
          ],
        ),
      );
    }
    return _buildDropdownField(
      value: _selectedBodyKey,
      hint: '본문 선택',
      items: _bodyPdfs
          .map((p) => DropdownMenuItem(
                value: p.key,
                child: Text(
                  p.simpleLabel,
                  overflow: TextOverflow.ellipsis,
                ),
              ))
          .toList(),
      onChanged: (value) {
        setState(() {
          _selectedBodyKey = value;
          _setPageOffsetForSelection();
        });
      },
    );
  }

  Widget _buildPageOffsetField() {
    final bool disabled = _selectedBookId == null || _selectedBody == null;
    return Container(
      height: 44,
      constraints: const BoxConstraints(minWidth: 120, maxWidth: 160),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: disabled ? const Color(0xFF232323) : const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF3A3A3A)),
      ),
      child: TextField(
        controller: _pageOffsetCtrl,
        enabled: !disabled,
        keyboardType: TextInputType.number,
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'^-?\d*$')),
        ],
        style: const TextStyle(color: Colors.white, fontSize: 14),
        decoration: const InputDecoration(
          border: InputBorder.none,
          hintText: '0',
          hintStyle: TextStyle(color: Colors.white38, fontSize: 14),
          isDense: true,
          contentPadding: EdgeInsets.symmetric(vertical: 12),
        ),
        onChanged: (value) {
          final bookId = _selectedBookId;
          final gradeLabel = _selectedBody?.gradeLabel;
          if (bookId == null || gradeLabel == null || gradeLabel.isEmpty) return;
          final trimmed = value.trim();
          if (trimmed.isEmpty || trimmed == '-') {
            _pageOffsetByKey.remove(_pageOffsetKey(bookId, gradeLabel));
            return;
          }
          final parsed = int.tryParse(trimmed);
          if (parsed == null) return;
          _pageOffsetByKey[_pageOffsetKey(bookId, gradeLabel)] = parsed;
        },
      ),
    );
  }

  Widget _buildSaveButton() {
    final disabled = _selectedBookId == null || _selectedBody == null || _isSaving;
    return SizedBox(
      height: 40,
      child: FilledButton.icon(
        onPressed: disabled ? null : _saveTextbookMetadata,
        style: FilledButton.styleFrom(
          backgroundColor: _rsAccent,
          disabledBackgroundColor: const Color(0xFF2A2A2A),
          padding: const EdgeInsets.symmetric(horizontal: 16),
        ),
        icon: _isSaving
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: _rsText),
              )
            : const Icon(Icons.save, size: 18, color: _rsText),
        label: Text(
          _isSaving ? '저장 중...' : '저장',
          style: const TextStyle(color: _rsText, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  Future<void> _saveTextbookMetadata() async {
    if (_isSaving) return;
    final bookId = _selectedBookId;
    final body = _selectedBody;
    if (bookId == null) {
      _showError('교재를 선택하세요.');
      return;
    }
    if (body == null) {
      _showError('본문을 선택하세요.');
      return;
    }
    final academyId = _selectedBook?.academyId;
    if (academyId == null || academyId.isEmpty) {
      _showError('학원 정보를 찾을 수 없습니다.');
      return;
    }
    final payload = _buildMetadataPayload(body);
    final pageOffset = _currentPageOffset();
    setState(() => _isSaving = true);
    try {
      await _supabase.from('textbook_metadata').upsert(
        {
          'academy_id': academyId,
          'book_id': bookId,
          'grade_label': body.gradeLabel,
          'page_offset': pageOffset,
          'payload': payload,
        },
        onConflict: 'academy_id,book_id,grade_label',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('저장되었습니다.'),
          backgroundColor: Color(0xFF2E7D32),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _showError('저장 실패: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Map<String, dynamic> _buildMetadataPayload(_PdfEntry body) {
    return {
      'version': 1,
      'book_id': _selectedBookId,
      'grade_label': body.gradeLabel,
      'body_url': body.url,
      'units': _serializeBigUnits(),
    };
  }

  List<Map<String, dynamic>> _serializeBigUnits() {
    final out = <Map<String, dynamic>>[];
    for (int i = 0; i < _bigUnits.length; i++) {
      final unit = _bigUnits[i];
      out.add({
        'name': unit.nameCtrl.text.trim(),
        'order_index': i,
        'middles': _serializeMidUnits(unit.middles),
      });
    }
    return out;
  }

  List<Map<String, dynamic>> _serializeMidUnits(List<_MidUnitNode> mids) {
    final out = <Map<String, dynamic>>[];
    for (int i = 0; i < mids.length; i++) {
      final unit = mids[i];
      out.add({
        'name': unit.nameCtrl.text.trim(),
        'order_index': i,
        'smalls': _serializeSmallUnits(unit.smalls),
      });
    }
    return out;
  }

  List<Map<String, dynamic>> _serializeSmallUnits(List<_SmallUnitNode> smalls) {
    final out = <Map<String, dynamic>>[];
    for (int i = 0; i < smalls.length; i++) {
      final unit = smalls[i];
      final start = _parsePositiveInt(unit.startPageCtrl.text);
      final end = _parsePositiveInt(unit.endPageCtrl.text);
      final counts = <String, int>{};
      for (final entry in unit.pageCountCtrls.entries) {
        final raw = entry.value.text.trim();
        if (raw.isEmpty || raw == '-') continue;
        final v = int.tryParse(raw);
        if (v == null) continue;
        if (start != null && end != null) {
          if (entry.key < start || entry.key > end) continue;
        }
        counts[entry.key.toString()] = v;
      }
      out.add({
        'name': unit.nameCtrl.text.trim(),
        'order_index': i,
        'start_page': start,
        'end_page': end,
        'page_counts': counts,
      });
    }
    return out;
  }

  int? _currentPageOffset() {
    final bookId = _selectedBookId;
    final gradeLabel = _selectedBody?.gradeLabel;
    if (bookId == null || gradeLabel == null || gradeLabel.isEmpty) return null;
    return _pageOffsetByKey[_pageOffsetKey(bookId, gradeLabel)];
  }

  Widget _buildDropdownField({
    required String? value,
    required String hint,
    required List<DropdownMenuItem<String>> items,
    required ValueChanged<String?> onChanged,
  }) {
    return Container(
      height: 44,
      constraints: const BoxConstraints(minWidth: 260, maxWidth: 420),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF3A3A3A)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          hint: Text(hint, style: const TextStyle(color: Colors.white54, fontSize: 14)),
          dropdownColor: const Color(0xFF2A2A2A),
          style: const TextStyle(color: Colors.white, fontSize: 14),
          icon: const Icon(Icons.arrow_drop_down, color: Colors.white70, size: 20),
          isExpanded: true,
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _buildStatusField({required Widget child}) {
    return Container(
      height: 44,
      constraints: const BoxConstraints(minWidth: 260, maxWidth: 420),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF3A3A3A)),
      ),
      child: Align(alignment: Alignment.centerLeft, child: child),
    );
  }

  Widget _buildSelectionCard() {
    final book = _selectedBook;
    final body = _selectedBody;
    final sol = _linkedSol;
    final ans = _linkedAns;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF18181A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      child: _selectedBookId == null
          ? const Center(
              child: Text(
                '교재를 선택하면 연결된 PDF가 표시됩니다.',
                style: TextStyle(color: Color(0xFF8A8A8A), fontSize: 14),
              ),
            )
          : _isLoadingPdfs
              ? const Center(child: CircularProgressIndicator(color: Colors.white54))
              : _allPdfs.isEmpty
                  ? const Center(
                      child: Text(
                        '연결된 PDF가 없습니다.',
                        style: TextStyle(color: Color(0xFF8A8A8A), fontSize: 14),
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '선택 정보',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 12),
                        _infoRow('교재', book?.name ?? '-'),
                        _infoRow('과정', body?.gradeLabel ?? '-'),
                        _infoRow('본문', body?.fileName ?? '-'),
                        _infoRow('해설', (sol?.url.isNotEmpty ?? false) ? sol!.fileName : '-'),
                        _infoRow('정답', (ans?.url.isNotEmpty ?? false) ? ans!.fileName : '-'),
                        _infoRow(
                          '본문 경로',
                          (body?.url.isNotEmpty ?? false) ? body!.url : '-',
                          selectable: true,
                        ),
                        _infoRow(
                          '해설 경로',
                          (sol?.url.isNotEmpty ?? false) ? sol!.url : '-',
                          selectable: true,
                        ),
                        _infoRow(
                          '정답 경로',
                          (ans?.url.isNotEmpty ?? false) ? ans!.url : '-',
                          selectable: true,
                        ),
                        if (_selectedBodyKey == null)
                          const Padding(
                            padding: EdgeInsets.only(top: 12),
                            child: Text(
                              '본문을 선택하면 해설/정답이 자동으로 연결됩니다.',
                              style: TextStyle(color: Color(0xFF8A8A8A), fontSize: 13),
                            ),
                          ),
                      ],
                    ),
    );
  }

  Widget _buildChapterTreeCard() {
    final bool disabled = _selectedBookId == null;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF18181A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '단원 구성',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              OutlinedButton.icon(
                onPressed: disabled ? null : _addBigUnit,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white70,
                  side: const BorderSide(color: Color(0xFF2A2A2A)),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('대단원 추가'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            '대단원 → 중단원 → 소단원 순서로 입력하세요. 소단원에는 페이지 범위를 기록합니다.',
            style: TextStyle(color: Color(0xFF8A8A8A), fontSize: 13),
          ),
          const SizedBox(height: 12),
          if (disabled)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                '교재를 선택하면 단원 정보를 입력할 수 있습니다.',
                style: TextStyle(color: Color(0xFF8A8A8A), fontSize: 14),
              ),
            )
          else if (_bigUnits.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                '대단원을 추가해 주세요.',
                style: TextStyle(color: Color(0xFF8A8A8A), fontSize: 14),
              ),
            )
          else
            Column(
              children: [
                for (int i = 0; i < _bigUnits.length; i++) ...[
                  _buildBigUnitNode(
                    _bigUnits[i],
                    index: i,
                    siblingCount: _bigUnits.length,
                    ancestorHasNext: const [],
                  ),
                  if (i < _bigUnits.length - 1) const SizedBox(height: 8),
                ],
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildBigUnitNode(
    _BigUnitNode unit, {
    required int index,
    required int siblingCount,
    required List<bool> ancestorHasNext,
  }) {
    final hasNextSibling = index < siblingCount - 1;
    final nextAncestorHasNext = [...ancestorHasNext, hasNextSibling];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildTreeRow(
          depth: 0,
          ancestorHasNext: ancestorHasNext,
          hasNextSibling: hasNextSibling,
          child: Row(
            children: [
              _buildUnitLabel('대단원 ${index + 1}'),
              const SizedBox(width: 8),
              Expanded(child: _buildTextField(unit.nameCtrl, hint: '대단원 이름')),
              const SizedBox(width: 6),
              IconButton(
                tooltip: '중단원 추가',
                visualDensity: VisualDensity.compact,
                onPressed: () => _addMidUnit(unit),
                icon: const Icon(Icons.add, color: Colors.white54, size: 18),
              ),
              IconButton(
                tooltip: '대단원 삭제',
                visualDensity: VisualDensity.compact,
                onPressed: () => _removeBigUnit(unit),
                icon: const Icon(Icons.close, color: Colors.white38, size: 18),
              ),
            ],
          ),
        ),
        if (unit.middles.isNotEmpty)
          Column(
            children: [
              for (int i = 0; i < unit.middles.length; i++) ...[
                const SizedBox(height: 6),
                _buildMidUnitNode(
                  unit,
                  unit.middles[i],
                  index: i,
                  siblingCount: unit.middles.length,
                  ancestorHasNext: nextAncestorHasNext,
                ),
              ],
            ],
          ),
      ],
    );
  }

  Widget _buildMidUnitNode(
    _BigUnitNode parent,
    _MidUnitNode unit, {
    required int index,
    required int siblingCount,
    required List<bool> ancestorHasNext,
  }) {
    final hasNextSibling = index < siblingCount - 1;
    final nextAncestorHasNext = [...ancestorHasNext, hasNextSibling];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildTreeRow(
          depth: 1,
          ancestorHasNext: ancestorHasNext,
          hasNextSibling: hasNextSibling,
          child: Row(
            children: [
              _buildUnitLabel('중단원 ${index + 1}'),
              const SizedBox(width: 8),
              Expanded(child: _buildTextField(unit.nameCtrl, hint: '중단원 이름')),
              const SizedBox(width: 6),
              IconButton(
                tooltip: '소단원 추가',
                visualDensity: VisualDensity.compact,
                onPressed: () => _addSmallUnit(unit),
                icon: const Icon(Icons.add, color: Colors.white54, size: 18),
              ),
              IconButton(
                tooltip: '중단원 삭제',
                visualDensity: VisualDensity.compact,
                onPressed: () => _removeMidUnit(parent, unit),
                icon: const Icon(Icons.close, color: Colors.white38, size: 18),
              ),
            ],
          ),
        ),
        if (unit.smalls.isNotEmpty)
          Column(
            children: [
              for (int i = 0; i < unit.smalls.length; i++) ...[
                const SizedBox(height: 6),
                _buildSmallUnitNode(
                  unit,
                  unit.smalls[i],
                  index: i,
                  siblingCount: unit.smalls.length,
                  ancestorHasNext: nextAncestorHasNext,
                ),
              ],
            ],
          ),
      ],
    );
  }

  Widget _buildSmallUnitNode(
    _MidUnitNode parent,
    _SmallUnitNode unit, {
    required int index,
    required int siblingCount,
    required List<bool> ancestorHasNext,
  }) {
    final hasNextSibling = index < siblingCount - 1;
    return _buildTreeRow(
      depth: 2,
      ancestorHasNext: ancestorHasNext,
      hasNextSibling: hasNextSibling,
      child: Row(
        children: [
          _buildUnitLabel('소단원'),
          const SizedBox(width: 8),
          Expanded(child: _buildTextField(unit.nameCtrl, hint: '소단원 이름')),
          const SizedBox(width: 6),
          SizedBox(
            width: 70,
            child: _buildTextField(
              unit.startPageCtrl,
              hint: '시작',
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 70,
            child: _buildTextField(
              unit.endPageCtrl,
              hint: '끝',
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(width: 6),
          TextButton(
            onPressed: () => _openPageCountDialog(unit),
            style: TextButton.styleFrom(
              foregroundColor: Colors.white70,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              minimumSize: const Size(0, 28),
              side: const BorderSide(color: Color(0xFF333333)),
            ),
            child: const Text('문항수', style: TextStyle(fontSize: 12)),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: '소단원 삭제',
            visualDensity: VisualDensity.compact,
            onPressed: () => _removeSmallUnit(parent, unit),
            icon: const Icon(Icons.close, color: Colors.white38, size: 18),
          ),
        ],
      ),
    );
  }

  Widget _buildTreeRow({
    required int depth,
    required List<bool> ancestorHasNext,
    required bool hasNextSibling,
    required Widget child,
  }) {
    final indentWidth = depth > 0
        ? (depth * _treeIndentStep) + _treeConnectorWidth
        : (_treeIndentStep / 2);
    return SizedBox(
      height: _treeRowHeight,
      child: Row(
        children: [
          if (depth > 0)
            SizedBox(
              width: indentWidth,
              height: _treeRowHeight,
              child: CustomPaint(
                painter: _TreeIndentPainter(
                  depth: depth,
                  ancestorHasNext: ancestorHasNext,
                  hasNextSibling: hasNextSibling,
                  indentStep: _treeIndentStep,
                  connectorWidth: _treeConnectorWidth,
                  lineColor: _treeLineColor,
                ),
              ),
            )
          else
            SizedBox(width: indentWidth),
          Expanded(child: child),
        ],
      ),
    );
  }

  Widget _buildUnitLabel(String label) {
    return SizedBox(
      width: 78,
      child: Text(
        label,
        style: const TextStyle(color: Color(0xFFB3B3B3), fontSize: 12),
      ),
    );
  }

  Widget _buildTextField(
    TextEditingController controller, {
    required String hint,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    TextAlign textAlign = TextAlign.left,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      textAlign: textAlign,
      maxLines: 1,
      style: const TextStyle(color: Colors.white, fontSize: 13),
      decoration: InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white38, fontSize: 12),
        filled: true,
        fillColor: const Color(0xFF1F1F1F),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF333333)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF333333)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF4A4A4A)),
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value, {bool selectable = false}) {
    final textStyle = const TextStyle(color: Colors.white70, fontSize: 14);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(label, style: const TextStyle(color: Color(0xFFB3B3B3), fontSize: 13)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: selectable
                ? SelectableText(value, style: textStyle)
                : Text(value, style: textStyle),
          ),
        ],
      ),
    );
  }

  Future<void> _openPageCountDialog(_SmallUnitNode unit) async {
    final start = _parsePositiveInt(unit.startPageCtrl.text);
    final end = _parsePositiveInt(unit.endPageCtrl.text);
    if (start == null || end == null) {
      _showError('시작/끝 페이지를 입력하세요.');
      return;
    }
    if (start > end) {
      _showError('시작 페이지가 끝 페이지보다 클 수 없습니다.');
      return;
    }
    unit.ensurePageControllers(start, end);
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final total = end - start + 1;
        return AlertDialog(
          backgroundColor: _rsBg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: _rsBorder),
          ),
          title: const Text(
            '문항수 입력',
            style: TextStyle(color: _rsText, fontWeight: FontWeight.w900, fontSize: 18),
          ),
          content: SizedBox(
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '페이지 $start ~ $end',
                  style: const TextStyle(color: _rsTextSub, fontSize: 14),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: _rsPanelBg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _rsBorder),
                  ),
                  child: Row(
                    children: const [
                      SizedBox(
                        width: 70,
                        child: Text('페이지', style: TextStyle(color: _rsTextSub, fontSize: 13)),
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text('문항수', style: TextStyle(color: _rsTextSub, fontSize: 13)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 360),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: total,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final page = start + index;
                      final ctrl = unit.pageCountController(page);
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: _rsPanelBg,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: _rsBorder),
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 70,
                              child: Text(
                                '$page',
                                style: const TextStyle(
                                  color: _rsText,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: ctrl,
                                keyboardType: TextInputType.number,
                                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: _rsText, fontSize: 15),
                                cursorColor: _rsAccent,
                                decoration: InputDecoration(
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                  hintText: '0',
                                  hintStyle: const TextStyle(color: _rsTextSub, fontSize: 14),
                                  filled: true,
                                  fillColor: _rsFieldBg,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: const BorderSide(color: _rsBorder),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: const BorderSide(color: _rsBorder),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: const BorderSide(color: _rsAccent, width: 1.2),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('닫기', style: TextStyle(color: _rsTextSub, fontSize: 14)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _rsAccent),
              onPressed: () => Navigator.pop(ctx),
              child: const Text('완료', style: TextStyle(fontSize: 14, color: _rsText)),
            ),
          ],
        );
      },
    );
  }

  int? _parsePositiveInt(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final parsed = int.tryParse(trimmed);
    if (parsed == null || parsed <= 0) return null;
    return parsed;
  }
}

class _BookEntry {
  final String id;
  final String? academyId;
  final String name;
  final int? orderIndex;
  _BookEntry({
    required this.id,
    required this.name,
    this.academyId,
    this.orderIndex,
  });
}

class _PdfEntry {
  final String key;
  final String gradeLabel;
  final String kind;
  final String kindLabel;
  final String url;
  final String fileName;
  _PdfEntry({
    required this.key,
    required this.gradeLabel,
    required this.kind,
    required this.kindLabel,
    required this.url,
    required this.fileName,
  });

  String get simpleLabel => '$gradeLabel · $fileName';
  String get dropdownLabel => '$gradeLabel · $kindLabel · $fileName';
}

class _BigUnitNode {
  final TextEditingController nameCtrl;
  final List<_MidUnitNode> middles = [];

  _BigUnitNode({String? name}) : nameCtrl = TextEditingController(text: name ?? '');

  void dispose() {
    nameCtrl.dispose();
    for (final m in middles) {
      m.dispose();
    }
  }
}

class _MidUnitNode {
  final TextEditingController nameCtrl;
  final List<_SmallUnitNode> smalls = [];

  _MidUnitNode({String? name}) : nameCtrl = TextEditingController(text: name ?? '');

  void dispose() {
    nameCtrl.dispose();
    for (final s in smalls) {
      s.dispose();
    }
  }
}

class _SmallUnitNode {
  final TextEditingController nameCtrl;
  final TextEditingController startPageCtrl;
  final TextEditingController endPageCtrl;
  final Map<int, TextEditingController> pageCountCtrls = {};

  _SmallUnitNode({
    String? name,
    String? startPage,
    String? endPage,
  })  : nameCtrl = TextEditingController(text: name ?? ''),
        startPageCtrl = TextEditingController(text: startPage ?? ''),
        endPageCtrl = TextEditingController(text: endPage ?? '');

  void dispose() {
    nameCtrl.dispose();
    startPageCtrl.dispose();
    endPageCtrl.dispose();
    for (final ctrl in pageCountCtrls.values) {
      ctrl.dispose();
    }
    pageCountCtrls.clear();
  }

  void ensurePageControllers(int start, int end) {
    final keys = pageCountCtrls.keys.toList();
    for (final k in keys) {
      if (k < start || k > end) {
        pageCountCtrls[k]?.dispose();
        pageCountCtrls.remove(k);
      }
    }
    for (int p = start; p <= end; p++) {
      pageCountCtrls.putIfAbsent(p, () => TextEditingController());
    }
  }

  TextEditingController pageCountController(int page) {
    return pageCountCtrls.putIfAbsent(page, () => TextEditingController());
  }
}

class _TreeIndentPainter extends CustomPainter {
  const _TreeIndentPainter({
    required this.depth,
    required this.ancestorHasNext,
    required this.hasNextSibling,
    required this.indentStep,
    required this.connectorWidth,
    required this.lineColor,
  });

  final int depth;
  final List<bool> ancestorHasNext;
  final bool hasNextSibling;
  final double indentStep;
  final double connectorWidth;
  final Color lineColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (depth <= 0) return;
    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = _treeLineWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final centerY = size.height / 2;

    for (var i = 0; i < depth - 1; i++) {
      if (i >= ancestorHasNext.length || !ancestorHasNext[i]) continue;
      final x = (i * indentStep) + (indentStep / 2);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }

    final elbowX = ((depth - 1) * indentStep) + (indentStep / 2);
    final rawRadius =
        _treeCornerRadius > connectorWidth ? connectorWidth : _treeCornerRadius;
    final radius = rawRadius > centerY ? centerY : rawRadius;
    final elbowPath = Path()
      ..moveTo(elbowX, 0)
      ..lineTo(elbowX, centerY - radius)
      ..quadraticBezierTo(elbowX, centerY, elbowX + radius, centerY)
      ..lineTo(elbowX + connectorWidth, centerY);
    canvas.drawPath(elbowPath, paint);
    if (hasNextSibling) {
      canvas.drawLine(Offset(elbowX, centerY), Offset(elbowX, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _TreeIndentPainter oldDelegate) {
    return oldDelegate.depth != depth ||
        oldDelegate.ancestorHasNext != ancestorHasNext ||
        oldDelegate.hasNextSibling != hasNextSibling ||
        oldDelegate.indentStep != indentStep ||
        oldDelegate.connectorWidth != connectorWidth ||
        oldDelegate.lineColor != lineColor;
  }
}
