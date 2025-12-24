import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';
import 'package:mneme_flutter/widgets/dark_panel_route.dart';
import 'package:mneme_flutter/widgets/pdf/pdf_editor_dialog.dart';
import 'package:open_filex/open_filex.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'package:uuid/uuid.dart';
import '../../models/education_level.dart';
import '../../models/memo.dart';
import '../../services/ai_summary.dart';
import '../../services/data_manager.dart';
import '../memo_dialogs.dart';

const Color _rsBg = Color(0xFF0B1112);
const Color _rsPanelBg = Color(0xFF10171A);
const Color _rsFieldBg = Color(0xFF15171C);
const Color _rsBorder = Color(0xFF223131);
const Color _rsText = Color(0xFFEAF2F2);
const Color _rsTextSub = Color(0xFF9FB3B3);
const Color _rsAccent = Color(0xFF33A373);

enum RightSideSheetMode { none, answerKey, fileShortcut, pdfEdit, memo }

class RightSideSheet extends StatefulWidget {
  final VoidCallback onClose;
  /// showDialog를 띄울 컨텍스트(우측 사이드시트는 Overlay 안에 있어 Navigator가 없을 수 있음)
  final BuildContext? dialogContext;
  const RightSideSheet({
    super.key,
    required this.onClose,
    this.dialogContext,
  });

  @override
  State<RightSideSheet> createState() => _RightSideSheetState();
}

class _RightSideSheetState extends State<RightSideSheet> {
  RightSideSheetMode _mode = RightSideSheetMode.none;
  final List<_BookItem> _books = <_BookItem>[];
  Map<String, Map<String, String>> _pdfPathByBookAndGrade = <String, Map<String, String>>{};
  int _bookSeq = 0;
  String? _selectedBookId;

  late final List<_GradeOption> _grades = _buildAllGradeOptions();
  int _defaultGradeIndex = 0;
  int _lastGradeScrollMs = 0;
  bool _booksLoaded = false;
  bool _booksLoading = false;
  bool _pdfsLoaded = false;
  bool _pdfsLoading = false;

  // 메모 필터(전체 + 카테고리 3종)
  static const String _memoFilterAll = 'all';
  String _memoFilterKey = _memoFilterAll;

  // pdf 편집(범위 입력은 시트, 미리보기는 다이얼로그) 상태
  final TextEditingController _pdfEditInputCtrl = ImeAwareTextEditingController();
  final TextEditingController _pdfEditRangesCtrl = ImeAwareTextEditingController();
  final TextEditingController _pdfEditFileNameCtrl = ImeAwareTextEditingController();
  String? _pdfEditLastOutputPath;
  bool _pdfEditBusy = false;

  bool _looksLikeUuid(String s) {
    // uuid v4 뿐 아니라 일반 UUID 형식만 체크 (서버 컬럼이 uuid 타입)
    final re = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
    return re.hasMatch(s);
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadBooks());
    unawaited(_loadPdfs());
  }

  @override
  void dispose() {
    _pdfEditInputCtrl.dispose();
    _pdfEditRangesCtrl.dispose();
    _pdfEditFileNameCtrl.dispose();
    super.dispose();
  }

  String _currentGradeLabelForPdfEdit() {
    if (_grades.isEmpty) return '';
    final idx = _defaultGradeIndex.clamp(0, _grades.length - 1);
    return _grades[idx].label;
  }

  String _basenameWithoutExtension(String path) {
    final b = _basename(path);
    final dot = b.lastIndexOf('.');
    if (dot <= 0) return b;
    return b.substring(0, dot);
  }

  void _syncPdfEditDefaultFileName({required String inPath}) {
    final trimmed = inPath.trim();
    if (trimmed.isEmpty) return;
    // 사용자가 이미 파일명을 입력했다면 덮어쓰지 않음
    if (_pdfEditFileNameCtrl.text.trim().isNotEmpty) return;
    final base = _basenameWithoutExtension(trimmed);
    final grade = _currentGradeLabelForPdfEdit();
    _pdfEditFileNameCtrl.text = '${base}_${grade}_본문.pdf';
  }

  Future<void> _pickPdfEditInput() async {
    final typeGroup = XTypeGroup(label: 'PDF', extensions: const ['pdf']);
    final XFile? file = await openFile(acceptedTypeGroups: [typeGroup]);
    if (file == null) return;
    _pdfEditInputCtrl.text = file.path;
    _syncPdfEditDefaultFileName(inPath: file.path);
    if (mounted) setState(() {});
  }

  List<int> _parseRanges(String input, int maxPages) {
    final Set<int> pages = <int>{};
    for (final part in input.split(',')) {
      final t = part.trim();
      if (t.isEmpty) continue;
      if (t.contains('-')) {
        final sp = t.split('-');
        if (sp.length != 2) continue;
        final a = int.tryParse(sp[0].trim());
        final b = int.tryParse(sp[1].trim());
        if (a == null || b == null) continue;
        final start = a < 1 ? 1 : a;
        final end = b > maxPages ? maxPages : b;
        for (int i = start; i <= end; i++) pages.add(i);
      } else {
        final v = int.tryParse(t);
        if (v != null && v >= 1 && v <= maxPages) pages.add(v);
      }
    }
    final list = pages.toList()..sort();
    return list;
  }

  Future<void> _generatePdfFromRangesInSheet() async {
    if (_pdfEditBusy) return;
    final inPath = _pdfEditInputCtrl.text.trim();
    final ranges = _pdfEditRangesCtrl.text.trim();
    var outName = _pdfEditFileNameCtrl.text.trim();
    if (inPath.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('원본 PDF를 먼저 선택하세요.')));
      return;
    }
    if (!inPath.toLowerCase().endsWith('.pdf')) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PDF 파일만 지원합니다.')));
      return;
    }
    if (ranges.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('페이지 범위를 입력하세요.')));
      return;
    }
    if (outName.isEmpty) {
      final base = _basenameWithoutExtension(inPath);
      final grade = _currentGradeLabelForPdfEdit();
      outName = '${base}_${grade}_본문.pdf';
    }

    setState(() => _pdfEditBusy = true);
    try {
      final saveLoc = await getSaveLocation(suggestedName: outName);
      if (saveLoc == null) return;
      var outPath = saveLoc.path;
      if (!outPath.toLowerCase().endsWith('.pdf')) {
        outPath = '$outPath.pdf';
      }

      final inputBytes = await File(inPath).readAsBytes();
      final src = sf.PdfDocument(inputBytes: inputBytes);
      final selected = _parseRanges(ranges, src.pages.count);
      if (selected.isEmpty) {
        src.dispose();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('유효한 페이지 범위가 없습니다.')));
        }
        return;
      }

      final dst = sf.PdfDocument();
      try {
        dst.pageSettings.size = src.pageSettings.size;
        dst.pageSettings.orientation = src.pageSettings.orientation;
        dst.pageSettings.margins.all = 0;
      } catch (_) {}

      for (final pageNum in selected) {
        if (pageNum < 1 || pageNum > src.pages.count) continue;
        final srcPage = src.pages[pageNum - 1];
        final tmpl = srcPage.createTemplate();
        final newPage = dst.pages.add();
        try {
          newPage.graphics.drawPdfTemplate(tmpl, const Offset(0, 0));
        } catch (_) {}
      }

      final outBytes = await dst.save();
      src.dispose();
      dst.dispose();
      await File(outPath).writeAsBytes(outBytes, flush: true);
      if (!mounted) return;
      setState(() => _pdfEditLastOutputPath = outPath);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PDF 생성이 완료되었습니다.')));
    } finally {
      if (mounted) setState(() => _pdfEditBusy = false);
    }
  }

  Future<void> _openPdfPreviewSelectDialogFromSheet() async {
    final dlgCtx = widget.dialogContext ?? context;
    final inPath = _pdfEditInputCtrl.text.trim();
    if (inPath.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('원본 PDF를 먼저 선택하세요.')));
      return;
    }
    if (!inPath.toLowerCase().endsWith('.pdf')) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PDF 파일만 지원합니다.')));
      return;
    }
    var outName = _pdfEditFileNameCtrl.text.trim();
    if (outName.isEmpty) {
      final base = _basenameWithoutExtension(inPath);
      final grade = _currentGradeLabelForPdfEdit();
      outName = '${base}_${grade}_본문.pdf';
    }

    final out = await showDialog<String>(
      context: dlgCtx,
      useRootNavigator: true,
      builder: (_) => PdfPreviewSelectDialog(
        inputPath: inPath,
        suggestedOutputName: outName,
      ),
    );
    if (!mounted) return;
    if (out != null && out.trim().isNotEmpty) {
      setState(() => _pdfEditLastOutputPath = out.trim());
    }
  }

  Future<void> _loadBooks() async {
    if (_booksLoaded || _booksLoading) return;
    _booksLoading = true;

    try {
      final rows = await DataManager.instance.loadAnswerKeyBooks();
      if (!mounted) return;
      setState(() {
        _books
          ..clear()
          ..addAll(rows.map((r) {
            final id = (r['id'] as String?) ?? '';
            final name = (r['name'] as String?) ?? '';
            final desc = (r['description'] as String?) ?? '';
            final gradeKey = (r['grade_key'] as String?) ?? '';
            final gradeIndex = _gradeIndexForKey(gradeKey);
            return _BookItem(
              id: id,
              name: name,
              description: desc,
              gradeIndex: gradeIndex,
            );
          }));
      });
      _booksLoaded = true;
    } catch (_) {
      _booksLoaded = false;
    } finally {
      _booksLoading = false;
    }
  }

  Future<void> _loadPdfs() async {
    if (_pdfsLoaded || _pdfsLoading) return;
    _pdfsLoading = true;
    try {
      final rows = await DataManager.instance.loadAnswerKeyBookPdfs();
      final Map<String, Map<String, String>> next = <String, Map<String, String>>{};
      for (final r in rows) {
        final bookId = (r['book_id'] as String?) ?? '';
        final gradeKey = (r['grade_key'] as String?) ?? '';
        final path = (r['path'] as String?) ?? '';
        if (bookId.isEmpty || gradeKey.isEmpty || path.isEmpty) continue;
        next.putIfAbsent(bookId, () => <String, String>{})[gradeKey] = path;
      }
      if (!mounted) return;
      setState(() {
        _pdfPathByBookAndGrade = next;
        _pdfsLoaded = true;
      });
    } catch (_) {
      // ignore
    } finally {
      _pdfsLoading = false;
    }
  }

  int _gradeIndexForKey(String key) {
    if (key.isEmpty) return 0;
    final idx = _grades.indexWhere((g) => g.key == key);
    return idx == -1 ? 0 : idx;
  }

  Map<String, dynamic> _toBookRow(_BookItem b, int orderIndex) {
    final gradeKey = _grades.isEmpty
        ? ''
        : _grades[b.gradeIndex.clamp(0, _grades.length - 1)].key;
    return {
      'id': b.id,
      'name': b.name,
      'description': b.description,
      'grade_key': gradeKey,
      'order_index': orderIndex,
    };
  }

  Future<void> _saveAllBooks() async {
    // 과거 hot reload 상태/구버전 id('book_1' 등) 대비: 서버 저장 전에 uuid로 정규화
    final uuid = const Uuid();
    bool changed = false;
    final normalized = <_BookItem>[];
    for (final b in _books) {
      if (b.id.isEmpty || !_looksLikeUuid(b.id)) {
        changed = true;
        normalized.add(b.copyWith(id: uuid.v4()));
      } else {
        normalized.add(b);
      }
    }

    if (changed && mounted) {
      setState(() {
        _books
          ..clear()
          ..addAll(normalized);
      });
    }

    final rows = <Map<String, dynamic>>[
      for (int i = 0; i < normalized.length; i++) _toBookRow(normalized[i], i),
    ];
    await DataManager.instance.saveAnswerKeyBooks(rows);
  }

  Future<_BookPickResult?> _selectBookIndexForAttach(BuildContext ctx) async {
    return await showDialog<_BookPickResult>(
      context: ctx,
      useRootNavigator: true,
      builder: (context) => _BookSelectDialog(
        books: _books,
        grades: _grades,
      ),
    );
  }

  Future<bool> _confirmReplacePdf(BuildContext ctx) async {
    final result = await showDialog<bool>(
      context: ctx,
      useRootNavigator: true,
      builder: (context) {
        return AlertDialog(
          backgroundColor: _rsBg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: _rsBorder),
          ),
          title: const Text(
            'PDF 교체',
            style: TextStyle(color: _rsText, fontSize: 18, fontWeight: FontWeight.w900),
          ),
          content: const Text(
            '이미 이 학년에 연결된 PDF가 있습니다.\n새 PDF로 교체할까요?',
            style: TextStyle(color: _rsTextSub, fontSize: 13, fontWeight: FontWeight.w700, height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              style: TextButton.styleFrom(foregroundColor: _rsTextSub),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: _rsAccent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text('교체', style: TextStyle(fontWeight: FontWeight.w900)),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  Future<void> _onAddPdfPressed() async {
    if (_books.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('먼저 책을 추가해주세요.')),
      );
      return;
    }

    final typeGroup = XTypeGroup(label: 'PDF', extensions: const ['pdf']);
    final XFile? file = await openFile(acceptedTypeGroups: [typeGroup]);
    if (file == null) return;

    final dlgCtx = widget.dialogContext ?? context;
    final _BookPickResult? pick = await _selectBookIndexForAttach(dlgCtx);
    if (pick == null) return;

    // 선택 결과 반영(학년 포함) + uuid 정규화/서버 반영
    if (!mounted) return;
    final idx = pick.bookIndex.clamp(0, _books.length - 1);
    final gradeIdx = _grades.isEmpty ? 0 : pick.gradeIndex.clamp(0, _grades.length - 1);
    setState(() {
      _books[idx] = _books[idx].copyWith(gradeIndex: gradeIdx);
      _defaultGradeIndex = gradeIdx;
    });
    try { await _saveAllBooks(); } catch (_) {}

    if (!mounted) return;
    final book = _books[idx];
    setState(() => _selectedBookId = book.id);
    if (_grades.isEmpty) return;
    final grade = _grades[gradeIdx];

    final existing = _pdfPathByBookAndGrade[book.id]?[grade.key];
    if (existing != null && existing.isNotEmpty && existing != file.path) {
      final ok = await _confirmReplacePdf(dlgCtx);
      if (!ok) return;
    }

    final row = <String, dynamic>{
      'book_id': book.id,
      'grade_key': grade.key,
      'path': file.path,
      'name': file.name,
    };

    try {
      await DataManager.instance.saveAnswerKeyBookPdf(row);
      if (!mounted) return;
      setState(() {
        final m = _pdfPathByBookAndGrade.putIfAbsent(book.id, () => <String, String>{});
        m[grade.key] = file.path;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('연결됨: ${book.name} · ${grade.label}')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('PDF 연결 저장에 실패했습니다.')),
      );
    }
  }

  Future<void> _openPdfForBook(_BookItem book) async {
    if (mounted) {
      setState(() => _selectedBookId = book.id);
    }
    if (_grades.isEmpty) return;
    final paths = _pdfPathByBookAndGrade[book.id];
    if (paths == null || paths.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('연결된 PDF가 없습니다: -')),
      );
      return;
    }

    // 요청: "연결된 PDF가 있는 학년만" 보여주기 위해,
    // 선택 학년이 미연결이면 자동으로 연결된 첫 학년으로 보정하여 연다.
    final linkedIndices = <int>[];
    for (int i = 0; i < _grades.length; i++) {
      final k = _grades[i].key;
      final p = paths[k];
      if (p != null && p.trim().isNotEmpty) linkedIndices.add(i);
    }
    if (linkedIndices.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('연결된 PDF가 없습니다: -')),
      );
      return;
    }

    final current = book.gradeIndex.clamp(0, _grades.length - 1);
    final effective = linkedIndices.contains(current) ? current : linkedIndices.first;
    final grade = _grades[effective];
    final path = paths[grade.key];
    if (path == null || path.trim().isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('연결된 PDF가 없습니다: ${grade.label}')),
      );
      return;
    }

    // 상태와 UI 동기화: 유효한(연결된) 학년으로 보정
    if (mounted && effective != book.gradeIndex) {
      final bi = _books.indexWhere((b) => b.id == book.id);
      if (bi != -1) {
        setState(() {
          _books[bi] = _books[bi].copyWith(gradeIndex: effective);
          _defaultGradeIndex = effective;
        });
      }
    }
    await OpenFilex.open(path);
  }

  _BookItem? _findBookById(String? id) {
    if (id == null || id.isEmpty) return null;
    final idx = _books.indexWhere((b) => b.id == id);
    if (idx == -1) return null;
    return _books[idx];
  }

  Future<_BookItem?> _pickBookForAction(BuildContext dlgCtx) async {
    final selected = _findBookById(_selectedBookId);
    if (selected != null) return selected;
    if (_books.isEmpty) return null;
    if (_books.length == 1) {
      final b = _books.first;
      if (mounted) setState(() => _selectedBookId = b.id);
      return b;
    }
    final pick = await _selectBookIndexForAttach(dlgCtx);
    if (pick == null) return null;
    final safe = pick.bookIndex.clamp(0, _books.length - 1);
    final b = _books[safe];
    if (mounted) setState(() => _selectedBookId = b.id);
    return b;
  }

  String _basename(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return '';
    final parts = trimmed.split(RegExp(r'[\\/]+'));
    return parts.isEmpty ? trimmed : parts.last;
  }

  Future<void> _savePdfLinkForBook({
    required _BookItem book,
    required _GradeOption grade,
    required XFile file,
  }) async {
    // uuid 정규화: pdf link는 book_id(uuid)가 필요
    await _saveAllBooks();
    final row = <String, dynamic>{
      'book_id': book.id,
      'grade_key': grade.key,
      'path': file.path,
      'name': file.name,
    };
    await DataManager.instance.saveAnswerKeyBookPdf(row);
    if (!mounted) return;
    setState(() {
      final m = _pdfPathByBookAndGrade.putIfAbsent(book.id, () => <String, String>{});
      m[grade.key] = file.path;
    });
  }

  Future<void> _deletePdfLinkForBook({
    required _BookItem book,
    required _GradeOption grade,
  }) async {
    await DataManager.instance.deleteAnswerKeyBookPdf(bookId: book.id, gradeKey: grade.key);
    if (!mounted) return;
    setState(() {
      final m = _pdfPathByBookAndGrade[book.id];
      if (m == null) return;
      m.remove(grade.key);
      if (m.isEmpty) _pdfPathByBookAndGrade.remove(book.id);
    });
  }

  Future<void> _onEditPdfsPressed() async {
    if (_books.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('수정할 책이 없습니다.')));
      return;
    }
    final dlgCtx = widget.dialogContext ?? context;
    final book = await _pickBookForAction(dlgCtx);
    if (book == null) return;
    if (_grades.isEmpty) return;
    final initial = Map<String, String>.from(_pdfPathByBookAndGrade[book.id] ?? const <String, String>{});
    await showDialog<void>(
      context: dlgCtx,
      useRootNavigator: true,
      builder: (_) => _BookPdfEditDialog(
        book: book,
        grades: _grades,
        initialPaths: initial,
        basenameOf: _basename,
        onPickAndSave: (grade, file) => _savePdfLinkForBook(book: book, grade: grade, file: file),
        onDetach: (grade) => _deletePdfLinkForBook(book: book, grade: grade),
      ),
    );
  }

  Future<void> _onDeleteBookPressed() async {
    if (_books.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('삭제할 책이 없습니다.')));
      return;
    }
    final dlgCtx = widget.dialogContext ?? context;
    final book = await _pickBookForAction(dlgCtx);
    if (book == null) return;

    final ok = await showDialog<bool>(
      context: dlgCtx,
      useRootNavigator: true,
      builder: (context) {
        return AlertDialog(
          backgroundColor: _rsBg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: _rsBorder),
          ),
          title: const Text(
            '책 삭제',
            style: TextStyle(color: _rsText, fontSize: 18, fontWeight: FontWeight.w900),
          ),
          content: Text(
            '“${book.name}”을(를) 삭제할까요?\n연결된 PDF도 함께 삭제됩니다.',
            style: const TextStyle(color: _rsTextSub, fontSize: 13, fontWeight: FontWeight.w700, height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              style: TextButton.styleFrom(foregroundColor: _rsTextSub),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFB74C4C),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text('삭제', style: TextStyle(fontWeight: FontWeight.w900)),
            ),
          ],
        );
      },
    );
    if (ok != true) return;

    try {
      await DataManager.instance.deleteAnswerKeyBook(book.id);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _books.removeWhere((b) => b.id == book.id);
      _pdfPathByBookAndGrade.remove(book.id);
      if (_selectedBookId == book.id) _selectedBookId = null;
    });
    // 남은 책 order_index 저장
    unawaited(() async {
      try { await _saveAllBooks(); } catch (_) {}
    }());
  }

  void _onReorderBooks(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _books.length) return;
    if (newIndex < 0) return;
    if (newIndex > _books.length) newIndex = _books.length;
    if (oldIndex < newIndex) newIndex -= 1;
    if (oldIndex == newIndex) return;

    setState(() {
      final item = _books.removeAt(oldIndex);
      _books.insert(newIndex, item);
    });

    // 서버/로컬에 순서 저장(order_index)
    unawaited(() async {
      try {
        await _saveAllBooks();
      } catch (_) {}
    }());
  }

  List<_GradeOption> _buildAllGradeOptions() {
    final List<_GradeOption> out = <_GradeOption>[];
    final levels = <EducationLevel>[
      EducationLevel.elementary,
      EducationLevel.middle,
      EducationLevel.high,
    ];

    for (final level in levels) {
      final list = gradesByLevel[level] ?? const <Grade>[];
      for (final g in list) {
        // 'N수' 같은 특수 학년은 숫자 라벨 대신 이름을 사용
        final custom = g.isRepeater ? g.name : null;
        out.add(_GradeOption(level: g.level, grade: g.value, customLabel: custom));
      }
    }
    return out;
  }

  Future<void> _openAddBookDialog() async {
    final dlgCtx = widget.dialogContext ?? context;
    final result = await showDialog<_BookItem>(
      context: dlgCtx,
      useRootNavigator: true,
      barrierDismissible: true,
      builder: (_) => const _BookAddDialog(),
    );
    if (result == null) return;

    final newId = const Uuid().v4();
    setState(() {
      _bookSeq++;
      final name = result.name;
      _books.insert(
        0,
        result.copyWith(
          id: newId,
          name: name,
          gradeIndex: _defaultGradeIndex,
        ),
      );
    });

    // 서버/로컬 저장 (order_index 포함)
    try {
      await _saveAllBooks();
    } catch (_) {}
  }

  void _changeBookGradeByDelta({required String bookId, required int delta}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastGradeScrollMs < 60) return; // 자료탭과 동일한 간단 디바운스
    _lastGradeScrollMs = now;

    if (_grades.isEmpty) return;
    final idx = _books.indexWhere((b) => b.id == bookId);
    if (idx == -1) return;
    final paths = _pdfPathByBookAndGrade[bookId];
    if (paths == null || paths.isEmpty) return;

    // 요청: "연결된 PDF가 있는 학년만" 보여주기 위해, 학년 이동도 연결된 것만 순회
    final linkedIndices = <int>[];
    for (int i = 0; i < _grades.length; i++) {
      final k = _grades[i].key;
      final p = paths[k];
      if (p != null && p.trim().isNotEmpty) linkedIndices.add(i);
    }
    if (linkedIndices.isEmpty) return;

    final before = _books[idx].gradeIndex.clamp(0, _grades.length - 1);
    var pos = linkedIndices.indexOf(before);
    if (pos == -1) pos = 0;
    final nextPos = (pos + delta).clamp(0, linkedIndices.length - 1) as int;
    final next = linkedIndices[nextPos];
    if (before == next) return;

    setState(() {
      _books[idx] = _books[idx].copyWith(gradeIndex: next);
      _defaultGradeIndex = next;
    });

    // 해당 책만 서버/로컬 업서트 (order_index 유지)
    unawaited(() async {
      try {
        var b = _books[idx];
        if (b.id.isEmpty || !_looksLikeUuid(b.id)) {
          final newId = const Uuid().v4();
          if (!mounted) return;
          setState(() {
            _books[idx] = _books[idx].copyWith(id: newId);
          });
          b = _books[idx];
        }
        await DataManager.instance.saveAnswerKeyBook(_toBookRow(b, idx));
      } catch (_) {}
    }());
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: const BoxDecoration(
          color: _rsBg,
          border: Border(left: BorderSide(color: _rsBorder, width: 1)),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _TopIconBar(
                mode: _mode,
                onModeSelected: (m) {
                  setState(() => _mode = m);
                  if (m == RightSideSheetMode.answerKey) {
                    unawaited(_loadBooks());
                    unawaited(_loadPdfs());
                  }
                  if (m == RightSideSheetMode.memo) {
                    unawaited(DataManager.instance.loadMemos());
                  }
                },
                onClose: widget.onClose,
              ),
              const Divider(height: 1, color: Color(0x22FFFFFF)),
              Expanded(child: _buildBody()),
              if (_mode == RightSideSheetMode.answerKey) ...[
                const Divider(height: 1, color: Color(0x22FFFFFF)),
                _BottomAddBar(
                  onAddPressed: () {
                    unawaited(_onAddPdfPressed());
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    switch (_mode) {
      case RightSideSheetMode.answerKey:
        return _AnswerKeyPdfShortcutExplorer(
          books: _books,
          grades: _grades,
          pdfPathByBookAndGrade: _pdfPathByBookAndGrade,
          onAddBook: _openAddBookDialog,
          onBookGradeDelta: ({required String bookId, required int delta}) =>
              _changeBookGradeByDelta(bookId: bookId, delta: delta),
          onOpenBook: (book) => unawaited(_openPdfForBook(book)),
          onReorderBooks: _onReorderBooks,
          onEditPdfs: () => unawaited(_onEditPdfsPressed()),
          onDeleteBook: () => unawaited(_onDeleteBookPressed()),
        );
      case RightSideSheetMode.memo:
        return _MemoExplorer(
          memosListenable: DataManager.instance.memosNotifier,
          onAddMemo: () => unawaited(_onAddMemoPressed()),
          onEditMemo: (m) => unawaited(_onEditMemoPressed(m)),
          selectedFilterKey: _memoFilterKey,
          onFilterChanged: (k) => setState(() => _memoFilterKey = k),
          onOpenConsult: () => unawaited(_openConsultPage()),
        );
      case RightSideSheetMode.fileShortcut:
        return const SizedBox.expand();
      case RightSideSheetMode.pdfEdit:
        final inputPath = _pdfEditInputCtrl.text.trim();
        final hasPdf = inputPath.isNotEmpty && inputPath.toLowerCase().endsWith('.pdf');
        final hasRanges = _pdfEditRangesCtrl.text.trim().isNotEmpty;
        return Padding(
          padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'PDF 편집',
                style: TextStyle(color: _rsText, fontSize: 16, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _rsPanelBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _rsBorder),
                ),
                child: const Text(
                  '범위 입력(시트)에서 페이지를 지정하고, 필요하면 아래 “미리보기 선택”으로 검수/순서조정 후 생성하세요.',
                  style: TextStyle(color: _rsTextSub, fontSize: 13, fontWeight: FontWeight.w700, height: 1.35),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('입력 PDF', style: TextStyle(color: _rsTextSub, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 6),
                      TextField(
                        controller: _pdfEditInputCtrl,
                        onChanged: (v) {
                          if (_pdfEditBusy) return;
                          setState(() {});
                          if (v.trim().toLowerCase().endsWith('.pdf')) {
                            _syncPdfEditDefaultFileName(inPath: v);
                          }
                        },
                        style: const TextStyle(color: _rsText, fontWeight: FontWeight.w700),
                        decoration: InputDecoration(
                          hintText: '원본 PDF 경로',
                          hintStyle: const TextStyle(color: _rsTextSub),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: _rsBorder),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: _rsAccent, width: 1.4),
                          ),
                          filled: true,
                          fillColor: _rsFieldBg,
                        ),
                      ),
                      const SizedBox(height: 10),
                      DropTarget(
                        onDragDone: (detail) {
                          if (_pdfEditBusy) return;
                          if (detail.files.isEmpty) return;
                          final xf = detail.files.first;
                          final path = xf.path;
                          if (path != null && path.toLowerCase().endsWith('.pdf')) {
                            setState(() {
                              _pdfEditInputCtrl.text = path;
                              _syncPdfEditDefaultFileName(inPath: path);
                            });
                          }
                        },
                        child: Container(
                          height: 67,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: _rsFieldBg,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: _rsBorder),
                          ),
                          child: const Text(
                            '여기로 PDF를 드래그하여 선택',
                            style: TextStyle(color: _rsTextSub, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _pdfEditBusy ? null : _pickPdfEditInput,
                              icon: const Icon(Icons.folder_open, size: 16),
                              label: const Text('찾기'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: _rsTextSub,
                                side: const BorderSide(color: _rsBorder),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (hasPdf) ...[
                        const SizedBox(height: 14),
                        const Text(
                          '페이지 범위 (예: 1-3,5,7-9)',
                          style: TextStyle(color: _rsTextSub, fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 6),
                        TextField(
                          controller: _pdfEditRangesCtrl,
                          onChanged: (_) {
                            if (_pdfEditBusy) return;
                            setState(() {});
                          },
                          style: const TextStyle(color: _rsText, fontWeight: FontWeight.w700),
                          decoration: InputDecoration(
                            hintText: '쉼표로 구분, 범위는 하이픈',
                            hintStyle: const TextStyle(color: _rsTextSub),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(color: _rsBorder),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(color: _rsAccent, width: 1.4),
                            ),
                            filled: true,
                            fillColor: _rsFieldBg,
                          ),
                        ),
                      ],
                      if (hasPdf && hasRanges) ...[
                        const SizedBox(height: 14),
                        const Text('파일명', style: TextStyle(color: _rsTextSub, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 6),
                        TextField(
                          controller: _pdfEditFileNameCtrl,
                          style: const TextStyle(color: _rsText, fontWeight: FontWeight.w700),
                          decoration: InputDecoration(
                            hintText: '원본명_과정_본문.pdf',
                            hintStyle: const TextStyle(color: _rsTextSub),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(color: _rsBorder),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(color: _rsAccent, width: 1.4),
                            ),
                            filled: true,
                            fillColor: _rsFieldBg,
                          ),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          height: 48,
                          child: FilledButton.icon(
                            onPressed: _pdfEditBusy ? null : _generatePdfFromRangesInSheet,
                            icon: _pdfEditBusy
                                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Icon(Icons.save_outlined, size: 16),
                            label: const Text('범위로 생성'),
                            style: FilledButton.styleFrom(
                              backgroundColor: _rsAccent,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      if (_pdfEditLastOutputPath != null && _pdfEditLastOutputPath!.trim().isNotEmpty)
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: _rsFieldBg,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: _rsBorder.withOpacity(0.9)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('마지막 생성', style: TextStyle(color: _rsTextSub, fontSize: 12, fontWeight: FontWeight.w900)),
                              const SizedBox(height: 6),
                              Text(
                                _basename(_pdfEditLastOutputPath!),
                                style: const TextStyle(color: _rsText, fontSize: 13, fontWeight: FontWeight.w800),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  OutlinedButton(
                                    onPressed: () async {
                                      try {
                                        await OpenFilex.open(_pdfEditLastOutputPath!);
                                      } catch (_) {}
                                    },
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.white70,
                                      side: BorderSide(color: _rsBorder.withOpacity(0.9)),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                    ),
                                    child: const Text('열기'),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '과정: ${_currentGradeLabelForPdfEdit()}',
                                    style: const TextStyle(color: _rsTextSub, fontSize: 12, fontWeight: FontWeight.w800),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: (!_pdfEditBusy && hasPdf) ? _openPdfPreviewSelectDialogFromSheet : null,
                  icon: const Icon(Icons.preview_outlined, size: 16),
                  label: const Text('미리보기로 편집'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _rsTextSub,
                    side: const BorderSide(color: _rsBorder),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
            ],
          ),
        );
      case RightSideSheetMode.none:
      default:
        return const SizedBox.expand();
    }
  }

  Future<void> _onAddMemoPressed() async {
    final dlgCtx = widget.dialogContext ?? context;
    final initialCat = (_memoFilterKey == MemoCategory.schedule || _memoFilterKey == MemoCategory.inquiry)
        ? _memoFilterKey
        : null;
    final result = await showDialog<MemoCreateResult>(
      context: dlgCtx,
      useRootNavigator: true,
      builder: (_) => MemoInputDialog(initialCategoryKey: initialCat),
    );
    if (result == null) return;
    final text = result.text.trim();
    if (text.isEmpty) return;

    final now = DateTime.now();
    final trimmed = text;
    final String? pickedCategoryKey = result.categoryKey;
    final memo = Memo(
      id: const Uuid().v4(),
      original: trimmed,
      summary: '요약 중...',
      scheduledAt: await AiSummaryService.extractDateTime(trimmed),
      categoryKey: pickedCategoryKey ?? MemoCategory.inquiry,
      dismissed: false,
      createdAt: now,
      updatedAt: now,
    );
    await DataManager.instance.addMemo(memo);

    try {
      if (pickedCategoryKey != null && pickedCategoryKey.trim().isNotEmpty) {
        final summary = await AiSummaryService.summarize(memo.original);
        await DataManager.instance.updateMemo(
          memo.copyWith(
            summary: summary,
            categoryKey: MemoCategory.normalize(pickedCategoryKey),
            updatedAt: DateTime.now(),
          ),
        );
      } else {
        final r = await AiSummaryService.summarizeMemoWithCategory(
          memo.original,
          scheduledAt: memo.scheduledAt,
        );
        await DataManager.instance.updateMemo(
          memo.copyWith(
            summary: r.summary,
            categoryKey: r.categoryKey,
            updatedAt: DateTime.now(),
          ),
        );
      }
    } catch (_) {}
  }

  Future<void> _onEditMemoPressed(Memo item) async {
    final dlgCtx = widget.dialogContext ?? context;
    final edited = await showDialog<MemoEditResult>(
      context: dlgCtx,
      useRootNavigator: true,
      builder: (_) => MemoEditDialog(initial: item.original, initialScheduledAt: item.scheduledAt),
    );
    if (edited == null) return;
    if (edited.action == MemoEditAction.delete) {
      await DataManager.instance.deleteMemo(item.id);
      return;
    }

    final newOriginal = edited.text.trim();
    if (newOriginal.isEmpty) return;

    var updated = item.copyWith(
      original: newOriginal,
      summary: '요약 중...',
      scheduledAt: edited.scheduledAt,
      updatedAt: DateTime.now(),
    );
    await DataManager.instance.updateMemo(updated);

    try {
      final summary = await AiSummaryService.summarize(newOriginal);
      updated = updated.copyWith(summary: summary, updatedAt: DateTime.now());
      await DataManager.instance.updateMemo(updated);
    } catch (_) {}
  }

  Future<void> _openConsultPage() async {
    final ctx = widget.dialogContext ?? context;
    try {
      await Navigator.of(ctx, rootNavigator: true).push(
        DarkPanelRoute<void>(child: const _ConsultPlaceholderPage()),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('상담 페이지 이동을 사용할 수 없습니다.')));
      }
    }
  }
}

class _ConsultPlaceholderPage extends StatelessWidget {
  const _ConsultPlaceholderPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _rsBg,
      appBar: AppBar(
        backgroundColor: _rsBg,
        foregroundColor: _rsText,
        elevation: 0,
        title: const Text('상담', style: TextStyle(fontWeight: FontWeight.w900)),
      ),
      body: const Center(
        child: Text('상담 페이지(준비 중)', style: TextStyle(color: _rsTextSub, fontSize: 14, fontWeight: FontWeight.w800)),
      ),
    );
  }
}

class _TopIconBar extends StatelessWidget {
  final RightSideSheetMode mode;
  final ValueChanged<RightSideSheetMode> onModeSelected;
  final VoidCallback onClose;

  const _TopIconBar({required this.mode, required this.onModeSelected, required this.onClose});

  Color _colorFor(RightSideSheetMode m) => (mode == m) ? _rsAccent : Colors.white70;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          const SizedBox(width: 4),
          IconButton(
            tooltip: '닫기',
            onPressed: onClose,
            icon: const Icon(Icons.chevron_right),
            color: Colors.white70,
          ),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  tooltip: '답지 바로가기',
                  onPressed: () => onModeSelected(RightSideSheetMode.answerKey),
                  icon: const Icon(Icons.menu_book_outlined),
                  color: _colorFor(RightSideSheetMode.answerKey),
                ),
                IconButton(
                  tooltip: '파일 바로가기',
                  onPressed: () => onModeSelected(RightSideSheetMode.fileShortcut),
                  icon: const Icon(Icons.folder_open_outlined),
                  color: _colorFor(RightSideSheetMode.fileShortcut),
                ),
                IconButton(
                  tooltip: 'pdf 편집',
                  onPressed: () => onModeSelected(RightSideSheetMode.pdfEdit),
                  icon: const Icon(Icons.border_color_outlined),
                  color: _colorFor(RightSideSheetMode.pdfEdit),
                ),
                IconButton(
                  tooltip: '메모',
                  onPressed: () => onModeSelected(RightSideSheetMode.memo),
                  icon: const Icon(Icons.sticky_note_2_outlined),
                  color: _colorFor(RightSideSheetMode.memo),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

class _BottomAddBar extends StatelessWidget {
  final VoidCallback onAddPressed;
  const _BottomAddBar({required this.onAddPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: onAddPressed,
            style: FilledButton.styleFrom(
              backgroundColor: _rsAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('추가', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ),
      ),
    );
  }
}

// -------------------- 메모 --------------------

class _MemoExplorer extends StatelessWidget {
  final ValueListenable<List<Memo>> memosListenable;
  final VoidCallback onAddMemo;
  final void Function(Memo memo) onEditMemo;
  final String selectedFilterKey; // 'all' | MemoCategory.*
  final ValueChanged<String> onFilterChanged;
  final VoidCallback onOpenConsult;

  const _MemoExplorer({
    required this.memosListenable,
    required this.onAddMemo,
    required this.onEditMemo,
    required this.selectedFilterKey,
    required this.onFilterChanged,
    required this.onOpenConsult,
  });

  String _displayText(Memo m) {
    final summary = m.summary.trim();
    if (summary.isNotEmpty && summary != '요약 중...') return summary;
    return m.original.trim().isEmpty ? '(내용 없음)' : m.original.trim();
  }

  String _scheduleLabel(DateTime? s) {
    if (s == null) return '';
    final hh = s.hour.toString().padLeft(2, '0');
    final mm = s.minute.toString().padLeft(2, '0');
    return '${s.month}/${s.day} $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final filters = <MapEntry<String, String>>[
      const MapEntry(_RightSideSheetState._memoFilterAll, '전체'),
      MapEntry(MemoCategory.schedule, '일정'),
      MapEntry(MemoCategory.consult, '상담'),
      MapEntry(MemoCategory.inquiry, '문의'),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '메모',
            style: TextStyle(color: _rsText, fontSize: 16, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 12),
          _ExplorerHeader(
            leading: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '메모 추가',
                  onPressed: onAddMemo,
                  icon: const Icon(Icons.add, color: Colors.white70, size: 20),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '상담 메모 추가',
                  onPressed: onOpenConsult,
                  icon: const Icon(Icons.support_agent_outlined, color: Colors.white70, size: 20),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (int i = 0; i < filters.length; i++) ...[
                Expanded(
                  child: _MemoFilterPill(
                    label: filters[i].value,
                    selected: selectedFilterKey == filters[i].key,
                    onTap: () => onFilterChanged(filters[i].key),
                  ),
                ),
                if (i != filters.length - 1) const SizedBox(width: 8),
              ],
            ],
          ),
          const SizedBox(height: 14),
          Expanded(
            child: ValueListenableBuilder<List<Memo>>(
              valueListenable: memosListenable,
              builder: (context, memos, _) {
                if (memos.isEmpty) {
                  return const Center(
                    child: Text('메모 없음', style: TextStyle(color: _rsTextSub, fontSize: 13, fontWeight: FontWeight.w700)),
                  );
                }

                var list = [...memos]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
                if (selectedFilterKey != _RightSideSheetState._memoFilterAll) {
                  list = list.where((m) => m.categoryKey == selectedFilterKey).toList();
                }
                if (list.isEmpty) {
                  return const Center(
                    child: Text('메모 없음', style: TextStyle(color: _rsTextSub, fontSize: 13, fontWeight: FontWeight.w700)),
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final m = list[index];
                    final when = _scheduleLabel(m.scheduledAt);
                    return _MemoCard(
                      key: ValueKey(m.id),
                      dateLabel: '${m.createdAt.month}/${m.createdAt.day}',
                      scheduleLabel: when,
                      categoryLabel: MemoCategory.labelOf(m.categoryKey),
                      text: _displayText(m),
                      onTap: () => onEditMemo(m),
                      onDelete: () => unawaited(DataManager.instance.deleteMemo(m.id)),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _MemoCard extends StatelessWidget {
  final String dateLabel;
  final String scheduleLabel;
  final String categoryLabel;
  final String text;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _MemoCard({
    super.key,
    required this.dateLabel,
    required this.scheduleLabel,
    required this.categoryLabel,
    required this.text,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    Future<void> openMenu(Offset globalPos) async {
      // RightSideSheet는 MaterialApp.builder의 최상위 OverlayEntry 위에서 렌더링된다.
      // showMenu()는 Navigator Overlay에 붙어 사이드시트 뒤로 깔릴 수 있어,
      // 최상위 Overlay에 OverlayEntry로 메뉴를 직접 띄운다.
      final overlayState = Overlay.of(context, rootOverlay: true);
      if (overlayState == null) return;
      final overlayBox = overlayState.context.findRenderObject() as RenderBox?;
      if (overlayBox == null) return;

      final overlaySize = overlayBox.size;
      final local = overlayBox.globalToLocal(globalPos);
      const double menuW = 118;
      const double itemH = 36;
      const double pad = 6;
      final menuH = itemH * 2;

      double left = local.dx;
      double top = local.dy;
      // 화면 밖으로 나가지 않도록 보정
      left = left.clamp(pad, overlaySize.width - menuW - pad);
      top = top.clamp(pad, overlaySize.height - menuH - pad);

      final completer = Completer<_MemoContextAction?>();
      late final OverlayEntry entry;
      void close(_MemoContextAction? action) {
        if (!completer.isCompleted) completer.complete(action);
        entry.remove();
      }

      Widget menuItem({required String text, required Color color, required _MemoContextAction action}) {
        return SizedBox(
          height: itemH,
          child: InkWell(
            onTap: () => close(action),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(text, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w800)),
              ),
            ),
          ),
        );
      }

      entry = OverlayEntry(
        builder: (ctx) {
          return Stack(
            children: [
              Positioned.fill(
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: (_) => close(null),
                ),
              ),
              Positioned(
                left: left,
                top: top,
                width: menuW,
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    decoration: BoxDecoration(
                      color: _rsPanelBg,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: _rsBorder),
                      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.22), blurRadius: 12, offset: const Offset(0, 8))],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Material(
                      color: Colors.transparent,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          menuItem(text: '수정', color: _rsText, action: _MemoContextAction.edit),
                          Divider(height: 1, color: _rsBorder.withOpacity(0.7)),
                          menuItem(text: '삭제', color: const Color(0xFFB74C4C), action: _MemoContextAction.delete),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      );

      overlayState.insert(entry);
      final action = await completer.future;
      if (action == _MemoContextAction.edit) {
        onTap();
      } else if (action == _MemoContextAction.delete) {
        onDelete();
      }
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onSecondaryTapDown: (d) => openMenu(d.globalPosition),
        onLongPress: () {
          // 롱프레스에서는 카드 중앙 기준으로 메뉴를 열어준다.
          final box = context.findRenderObject() as RenderBox?;
          if (box == null) return;
          final center = box.localToGlobal(box.size.center(Offset.zero));
          openMenu(center);
        },
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _rsFieldBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _rsBorder.withOpacity(0.9)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Text(
                          dateLabel,
                          style: const TextStyle(color: _rsTextSub, fontSize: 12, fontWeight: FontWeight.w900),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: _rsPanelBg,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: _rsBorder),
                          ),
                          child: Text(
                            categoryLabel,
                            style: const TextStyle(color: _rsTextSub, fontSize: 11, fontWeight: FontWeight.w900),
                          ),
                        ),
                        if (scheduleLabel.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              '· $scheduleLabel',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                              style: const TextStyle(color: _rsTextSub, fontSize: 12, fontWeight: FontWeight.w700),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                text,
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _rsText, fontSize: 14, fontWeight: FontWeight.w800, height: 1.3),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _MemoContextAction { edit, delete }

class _MemoFilterPill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _MemoFilterPill({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? _rsAccent : _rsPanelBg,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: selected ? _rsAccent : _rsBorder, width: 1),
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : _rsTextSub,
              fontSize: 12,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ),
    );
  }
}

// -------------------- 답지: PDF 바로가기(윈도우 탐색기 느낌) --------------------

class _AnswerKeyPdfShortcutExplorer extends StatefulWidget {
  final List<_BookItem> books;
  final List<_GradeOption> grades;
  final Map<String, Map<String, String>> pdfPathByBookAndGrade;
  final VoidCallback onAddBook;
  final VoidCallback onEditPdfs;
  final VoidCallback onDeleteBook;
  final void Function({required String bookId, required int delta}) onBookGradeDelta;
  final void Function(_BookItem book) onOpenBook;
  final void Function(int oldIndex, int newIndex) onReorderBooks;

  const _AnswerKeyPdfShortcutExplorer({
    required this.books,
    required this.grades,
    required this.pdfPathByBookAndGrade,
    required this.onAddBook,
    required this.onEditPdfs,
    required this.onDeleteBook,
    required this.onBookGradeDelta,
    required this.onOpenBook,
    required this.onReorderBooks,
  });

  @override
  State<_AnswerKeyPdfShortcutExplorer> createState() => _AnswerKeyPdfShortcutExplorerState();
}

class _AnswerKeyPdfShortcutExplorerState extends State<_AnswerKeyPdfShortcutExplorer> {
  final ScrollController _scrollCtrl = ScrollController();

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'PDF 바로가기',
            style: TextStyle(color: _rsText, fontSize: 16, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 12),
          _ExplorerHeader(
            // Windows 탐색기 느낌: 툴바/주소줄을 단순화
            leading: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '책 추가',
                  onPressed: widget.onAddBook,
                  icon: const Icon(Icons.library_add_outlined, color: Colors.white70, size: 20),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'PDF 수정',
                  onPressed: widget.onEditPdfs,
                  icon: const Icon(Icons.edit_outlined, color: Colors.white70, size: 20),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '삭제',
                  onPressed: widget.onDeleteBook,
                  icon: const Icon(Icons.delete_outline, color: Colors.white70, size: 20),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: _BooksSection(
              books: widget.books,
              grades: widget.grades,
              pdfPathByBookAndGrade: widget.pdfPathByBookAndGrade,
              onBookGradeDelta: widget.onBookGradeDelta,
              onOpenBook: widget.onOpenBook,
              onReorderBooks: widget.onReorderBooks,
              scrollController: _scrollCtrl,
            ),
          ),
        ],
      ),
    );
  }
}

class _ExplorerHeader extends StatelessWidget {
  final Widget? leading;
  final Widget? trailing;
  const _ExplorerHeader({this.leading, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _rsPanelBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _rsBorder),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: 6),
          ],
          const Spacer(),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class _BooksSection extends StatelessWidget {
  final List<_BookItem> books;
  final List<_GradeOption> grades;
  final Map<String, Map<String, String>> pdfPathByBookAndGrade;
  final void Function({required String bookId, required int delta}) onBookGradeDelta;
  final void Function(_BookItem book) onOpenBook;
  final void Function(int oldIndex, int newIndex) onReorderBooks;
  final ScrollController scrollController;
  const _BooksSection({
    required this.books,
    required this.grades,
    required this.pdfPathByBookAndGrade,
    required this.onBookGradeDelta,
    required this.onOpenBook,
    required this.onReorderBooks,
    required this.scrollController,
  });

  @override
  Widget build(BuildContext context) {
    // 가장 바깥 컨테이너(패널 박스)는 제거하고, 카드만 쌓인다
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Text('책', style: TextStyle(color: _rsText, fontSize: 15, fontWeight: FontWeight.w900)),
            const SizedBox(width: 8),
            Text('${books.length}권', style: const TextStyle(color: _rsTextSub, fontSize: 12, fontWeight: FontWeight.w800)),
          ],
        ),
        const SizedBox(height: 8),
        if (books.isEmpty)
          const Text(
            '추가된 책이 없습니다.',
            style: TextStyle(color: _rsTextSub, fontSize: 12, fontWeight: FontWeight.w700),
          )
        else
          Expanded(
            child: Scrollbar(
              controller: scrollController,
              thumbVisibility: true,
              child: ReorderableListView.builder(
                scrollController: scrollController,
                buildDefaultDragHandles: false,
                itemCount: books.length,
                onReorder: onReorderBooks,
                proxyDecorator: (child, index, animation) {
                  // 기본 ReorderableListView 드래그 피드백은 Material(흰 배경)이 잡혀
                  // 아이템의 padding/여백 부분이 흰색으로 보일 수 있어, 패널 배경색으로 고정.
                  // 또한 "살짝 들리는" 드래그 피드백을 주기 위해 scale/translate/elevation을 적용한다.
                  final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
                  return AnimatedBuilder(
                    animation: curved,
                    builder: (context, _) {
                      final v = curved.value;
                      return Transform.translate(
                        offset: Offset(0, -4 * v),
                        child: Transform.scale(
                          scale: 1.0 + 0.02 * v,
                          child: Material(
                            color: _rsBg,
                            surfaceTintColor: Colors.transparent,
                            shadowColor: Colors.black.withOpacity(0.35),
                            elevation: 12 * v,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: child,
                          ),
                        ),
                      );
                    },
                  );
                },
                itemBuilder: (context, index) {
                  final b = books[index];
                  final gradeIdx = grades.isEmpty ? 0 : b.gradeIndex.clamp(0, grades.length - 1);

                  // 요청: 연결된 PDF가 있는 학년만 보이도록(순회/표시) "연결된 학년"을 먼저 산출
                  final paths = pdfPathByBookAndGrade[b.id];
                  final linkedIndices = <int>[];
                  if (paths != null && paths.isNotEmpty && grades.isNotEmpty) {
                    for (int i = 0; i < grades.length; i++) {
                      final k = grades[i].key;
                      final p = paths[k];
                      if (p != null && p.trim().isNotEmpty) linkedIndices.add(i);
                    }
                  }

                  final hasAnyLinked = linkedIndices.isNotEmpty;
                  final effectiveIdx = hasAnyLinked
                      ? (linkedIndices.contains(gradeIdx) ? gradeIdx : linkedIndices.first)
                      : 0;
                  final gradeLabel = hasAnyLinked ? grades[effectiveIdx].label : '-';
                  final linked = hasAnyLinked;

                  return ReorderableDelayedDragStartListener(
                    key: ValueKey(b.id),
                    index: index,
                    child: Padding(
                      padding: EdgeInsets.only(bottom: (index == books.length - 1) ? 0 : 8),
                      child: _BookCard(
                        item: b,
                        gradeLabel: gradeLabel,
                        onGradeDelta: (delta) => onBookGradeDelta(bookId: b.id, delta: delta),
                        linked: linked,
                        onOpen: () => onOpenBook(b),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }
}

class _BookCard extends StatelessWidget {
  final _BookItem item;
  final String gradeLabel;
  final void Function(int delta) onGradeDelta;
  final bool linked;
  final VoidCallback onOpen;
  const _BookCard({
    required this.item,
    required this.gradeLabel,
    required this.onGradeDelta,
    required this.linked,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    double gradeDragDx = 0.0;

    Widget buildGradeBadge() {
      final bg = linked ? _rsPanelBg : _rsPanelBg.withOpacity(0.35);
      final fg = linked ? _rsTextSub : Colors.white24;
      return SizedBox(
        width: 54, // 약 +20%
        height: 30, // 약 +20%
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.transparent), // 요청: 테두리 색상 투명
          ),
          child: Center(
            child: Text(
              gradeLabel,
              style: TextStyle(color: fg, fontSize: 13, fontWeight: FontWeight.w900),
              maxLines: 1,
              overflow: TextOverflow.clip,
              softWrap: false,
            ),
          ),
        ),
      );
    }

    final content = Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12), // 약 +20%
      decoration: BoxDecoration(
        color: _rsFieldBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _rsBorder.withOpacity(0.9)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  item.name,
                  style: const TextStyle(color: _rsText, fontSize: 16, fontWeight: FontWeight.w900),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 12),
              buildGradeBadge(),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            item.description,
            style: const TextStyle(color: _rsTextSub, fontSize: 13, fontWeight: FontWeight.w600, height: 1.25),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );

    // 카드 전체 영역(패딩/빈공간 포함)에서 좌우 스크롤/드래그가 먹히도록 카드 "바깥"으로 리스너/제스처를 올림
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerSignal: (signal) {
        if (signal is PointerScrollEvent) {
          final dx = signal.scrollDelta.dx;
          final dy = signal.scrollDelta.dy;
          // 수직 스크롤은 리스트 스크롤에 맡기고, 가로 입력만 과정 변경으로 사용
          if (dx != 0 && dx.abs() >= dy.abs()) {
            // 요청: 왼쪽(음수)=내려감(-1), 오른쪽(양수)=올라감(+1)
            onGradeDelta(dx < 0 ? -1 : 1);
          }
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onOpen,
        onHorizontalDragStart: (_) => gradeDragDx = 0.0,
        onHorizontalDragUpdate: (d) {
          gradeDragDx += d.delta.dx;
          if (gradeDragDx <= -48) {
            gradeDragDx = 0.0;
            onGradeDelta(-1);
          } else if (gradeDragDx >= 48) {
            gradeDragDx = 0.0;
            onGradeDelta(1);
          }
        },
        onHorizontalDragEnd: (_) => gradeDragDx = 0.0,
        onHorizontalDragCancel: () => gradeDragDx = 0.0,
        child: content,
      ),
    );
  }
}

class _ExplorerTableHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      decoration: BoxDecoration(
        color: _rsPanelBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _rsBorder),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: const Row(
        children: [
          Icon(Icons.description_outlined, color: _rsTextSub, size: 16),
          SizedBox(width: 8),
          Expanded(
            child: Text('이름', style: TextStyle(color: _rsTextSub, fontSize: 12, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _rsPanelBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _rsBorder),
      ),
      padding: const EdgeInsets.all(12),
      child: const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.folder_open, color: Colors.white24, size: 24),
          SizedBox(height: 10),
          Text(
            '등록된 PDF 바로가기가 없습니다.',
            style: TextStyle(color: _rsTextSub, fontSize: 12, fontWeight: FontWeight.w800),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: 6),
          Text(
            '아래 “추가” 버튼으로 PDF 경로를 등록할 예정입니다.',
            style: TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.w600, height: 1.3),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _ExplorerRow extends StatefulWidget {
  final _PdfShortcutItem item;
  const _ExplorerRow({required this.item});

  @override
  State<_ExplorerRow> createState() => _ExplorerRowState();
}

class _ExplorerRowState extends State<_ExplorerRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final bg = _hovered ? _rsFieldBg.withOpacity(0.75) : _rsFieldBg;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: InkWell(
        onTap: () {
          // TODO: implement
        },
        borderRadius: BorderRadius.circular(10),
        child: Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _rsBorder.withOpacity(0.9)),
          ),
          child: Row(
            children: [
              const Icon(Icons.picture_as_pdf_outlined, color: Colors.white54, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.item.name,
                  style: const TextStyle(color: _rsText, fontSize: 12, fontWeight: FontWeight.w700),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PdfShortcutItem {
  final String name;
  final String path;
  const _PdfShortcutItem({required this.name, required this.path});
}

class _BookItem {
  final String id;
  final String name;
  final String description;
  final int gradeIndex;
  const _BookItem({required this.id, required this.name, required this.description, required this.gradeIndex});

  _BookItem copyWith({String? id, String? name, String? description, int? gradeIndex}) => _BookItem(
        id: id ?? this.id,
        name: name ?? this.name,
        description: description ?? this.description,
        gradeIndex: gradeIndex ?? this.gradeIndex,
      );
}

class _GradeOption {
  final EducationLevel level;
  final int grade;
  final String? customLabel;
  const _GradeOption({required this.level, required this.grade, this.customLabel});

  String get key => '${level.index}-$grade';

  String get label {
    if (customLabel != null && customLabel!.isNotEmpty) {
      return customLabel!;
    }
    String p;
    switch (level) {
      case EducationLevel.elementary:
        p = '초';
        break;
      case EducationLevel.middle:
        p = '중';
        break;
      case EducationLevel.high:
        p = '고';
        break;
    }
    return '$p$grade';
  }
}

class _BookAddDialog extends StatefulWidget {
  const _BookAddDialog();

  @override
  State<_BookAddDialog> createState() => _BookAddDialogState();
}

class _BookSelectDialog extends StatelessWidget {
  final List<_BookItem> books;
  final List<_GradeOption> grades;
  const _BookSelectDialog({required this.books, required this.grades});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _rsBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: _rsBorder),
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      title: const Text(
        '책 선택',
        style: TextStyle(color: _rsText, fontSize: 18, fontWeight: FontWeight.w900),
      ),
      content: SizedBox(
        width: 520,
        height: 420,
        child: _BookSelectDialogBody(books: books, grades: grades),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop<_BookPickResult?>(null),
          style: TextButton.styleFrom(foregroundColor: _rsTextSub),
          child: const Text('취소'),
        ),
      ],
    );
  }
}

class _BookSelectDialogBody extends StatefulWidget {
  final List<_BookItem> books;
  final List<_GradeOption> grades;
  const _BookSelectDialogBody({required this.books, required this.grades});

  @override
  State<_BookSelectDialogBody> createState() => _BookSelectDialogBodyState();
}

class _BookSelectDialogBodyState extends State<_BookSelectDialogBody> {
  late final Map<String, int> _gradeIndexByBookId = <String, int>{
    for (int i = 0; i < widget.books.length; i++)
      widget.books[i].id: (widget.grades.isEmpty ? 0 : widget.books[i].gradeIndex.clamp(0, widget.grades.length - 1)),
  };

  @override
  Widget build(BuildContext context) {
    return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Divider(height: 1, color: Color(0x22FFFFFF)),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.separated(
                itemCount: widget.books.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final b = widget.books[index];
                  final gradeIdx = _gradeIndexByBookId[b.id] ?? 0;
                  final gradeLabel = widget.grades.isEmpty ? '-' : widget.grades[gradeIdx].label;
                  return InkWell(
                    onTap: () => Navigator.of(context).pop<_BookPickResult>(
                      _BookPickResult(bookIndex: index, gradeIndex: gradeIdx),
                    ),
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: _rsFieldBg,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: _rsBorder.withOpacity(0.9)),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  b.name,
                                  style: const TextStyle(color: _rsText, fontSize: 14, fontWeight: FontWeight.w900),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  b.description,
                                  style: const TextStyle(color: _rsTextSub, fontSize: 12, fontWeight: FontWeight.w600, height: 1.25),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          _GradePickBadge(
                            label: gradeLabel,
                            grades: widget.grades,
                            selectedIndex: gradeIdx,
                            onSelected: (i) => setState(() => _gradeIndexByBookId[b.id] = i),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
  }
}

class _GradePickBadge extends StatelessWidget {
  final String label;
  final List<_GradeOption> grades;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  const _GradePickBadge({
    required this.label,
    required this.grades,
    required this.selectedIndex,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 66,
      height: 30,
      child: PopupMenuButton<int>(
        tooltip: '학년 선택',
        onSelected: onSelected,
        color: _rsPanelBg,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: _rsBorder)),
        itemBuilder: (_) => [
          for (int i = 0; i < grades.length; i++)
            PopupMenuItem<int>(
              value: i,
              child: Text(
                grades[i].label,
                style: TextStyle(
                  color: i == selectedIndex ? _rsText : _rsTextSub,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
        ],
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _rsPanelBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.transparent),
          ),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: const TextStyle(color: _rsTextSub, fontSize: 13, fontWeight: FontWeight.w900),
                ),
                const SizedBox(width: 2),
                const Icon(Icons.keyboard_arrow_down, size: 16, color: _rsTextSub),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BookPickResult {
  final int bookIndex;
  final int gradeIndex;
  const _BookPickResult({required this.bookIndex, required this.gradeIndex});
}

class _BookPdfEditDialog extends StatefulWidget {
  final _BookItem book;
  final List<_GradeOption> grades;
  final Map<String, String> initialPaths;
  final String Function(String path) basenameOf;
  final Future<void> Function(_GradeOption grade, XFile file) onPickAndSave;
  final Future<void> Function(_GradeOption grade) onDetach;

  const _BookPdfEditDialog({
    required this.book,
    required this.grades,
    required this.initialPaths,
    required this.basenameOf,
    required this.onPickAndSave,
    required this.onDetach,
  });

  @override
  State<_BookPdfEditDialog> createState() => _BookPdfEditDialogState();
}

class _BookPdfEditDialogState extends State<_BookPdfEditDialog> {
  late Map<String, String> _paths = Map<String, String>.from(widget.initialPaths);
  bool _busy = false;

  Future<void> _open(String path) async {
    final p = path.trim();
    if (p.isEmpty) return;
    try {
      await OpenFilex.open(p);
    } catch (_) {}
  }

  Future<void> _pickAndSet(_GradeOption g) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final typeGroup = XTypeGroup(label: 'PDF', extensions: const ['pdf']);
      final XFile? file = await openFile(acceptedTypeGroups: [typeGroup]);
      if (file == null) return;
      await widget.onPickAndSave(g, file);
      if (!mounted) return;
      setState(() {
        _paths[g.key] = file.path;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _detach(_GradeOption g) async {
    if (_busy) return;
    if (!_paths.containsKey(g.key)) return;
    setState(() => _busy = true);
    try {
      await widget.onDetach(g);
      if (!mounted) return;
      setState(() {
        _paths.remove(g.key);
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _rsBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: _rsBorder),
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      title: Text(
        'PDF 수정 · ${widget.book.name}',
        style: const TextStyle(color: _rsText, fontSize: 18, fontWeight: FontWeight.w900),
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: 620,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Divider(height: 1, color: Color(0x22FFFFFF)),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.separated(
                itemCount: widget.grades.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final g = widget.grades[i];
                  final path = _paths[g.key];
                  final linked = path != null && path.trim().isNotEmpty;
                  final badgeBg = linked ? _rsPanelBg : _rsPanelBg.withOpacity(0.35);
                  final badgeFg = linked ? _rsTextSub : Colors.white24;
                  final fileLabel = linked ? widget.basenameOf(path) : '미연결';

                  return Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _rsFieldBg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _rsBorder.withOpacity(0.9)),
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 56,
                          height: 30,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: badgeBg,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: Colors.transparent),
                            ),
                            child: Center(
                              child: Text(
                                g.label,
                                style: TextStyle(color: badgeFg, fontSize: 13, fontWeight: FontWeight.w900),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            fileLabel,
                            style: TextStyle(
                              color: linked ? _rsText : _rsTextSub,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 12),
                        if (linked) ...[
                          OutlinedButton(
                            onPressed: _busy ? null : () => _open(path!),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white70,
                              side: BorderSide(color: _rsBorder.withOpacity(0.9)),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            child: const Text('열기'),
                          ),
                          const SizedBox(width: 8),
                        ],
                        OutlinedButton(
                          onPressed: _busy ? null : () => _pickAndSet(g),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white70,
                            side: BorderSide(color: _rsBorder.withOpacity(0.9)),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          child: Text(linked ? '변경' : '연결'),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: (!_busy && linked) ? () => _detach(g) : null,
                          style: TextButton.styleFrom(foregroundColor: _rsTextSub),
                          child: const Text('해제'),
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
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(foregroundColor: _rsTextSub),
          child: const Text('닫기'),
        ),
      ],
    );
  }
}

class _BookAddDialogState extends State<_BookAddDialog> {
  final TextEditingController _nameCtrl = ImeAwareTextEditingController();
  final TextEditingController _descCtrl = ImeAwareTextEditingController();

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _rsBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: _rsBorder),
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      title: const Text(
        '책 추가',
        style: TextStyle(color: _rsText, fontSize: 18, fontWeight: FontWeight.w900),
      ),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Divider(height: 1, color: Color(0x22FFFFFF)),
            const SizedBox(height: 14),
            TextField(
              controller: _nameCtrl,
              style: const TextStyle(color: _rsText),
              decoration: InputDecoration(
                labelText: '책 이름',
                labelStyle: const TextStyle(color: _rsTextSub, fontWeight: FontWeight.w800),
                filled: true,
                fillColor: _rsFieldBg,
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: _rsBorder.withOpacity(0.9)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: _rsAccent, width: 2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descCtrl,
              minLines: 3,
              maxLines: 4,
              style: const TextStyle(color: _rsText),
              decoration: InputDecoration(
                labelText: '설명',
                labelStyle: const TextStyle(color: _rsTextSub, fontWeight: FontWeight.w800),
                filled: true,
                fillColor: _rsFieldBg,
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: _rsBorder.withOpacity(0.9)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: _rsAccent, width: 2),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop<_BookItem?>(null),
          style: TextButton.styleFrom(foregroundColor: _rsTextSub),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () {
            final name = _nameCtrl.text.trim();
            final desc = _descCtrl.text.trim();
            if (name.isEmpty) return;
            Navigator.of(context).pop<_BookItem>(_BookItem(id: '', name: name, description: desc, gradeIndex: 0));
          },
          style: FilledButton.styleFrom(
            backgroundColor: _rsAccent,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: const Text('추가', style: TextStyle(fontWeight: FontWeight.w900)),
        ),
      ],
    );
  }
}


