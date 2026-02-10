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
import 'file_shortcut_tab.dart';
import '../pill_tab_selector.dart';
import '../../models/consult_note.dart';
import '../../models/memo.dart';
import '../../screens/consult/consult_notes_screen.dart';
import '../../services/consult_note_controller.dart';
import '../../services/consult_note_service.dart';
import '../../services/consult_inquiry_demand_service.dart';
import '../../services/consult_trial_lesson_service.dart';
import '../../services/ai_summary.dart';
import '../../services/data_manager.dart';
import '../../services/runtime_flags.dart';
import '../../services/tag_preset_service.dart';
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
  // 기본 탭: 이전 상태가 없다면 항상 "PDF 바로가기"부터 시작
  RightSideSheetMode _mode = RightSideSheetMode.answerKey;
  final List<_BookItem> _books = <_BookItem>[];
  Map<String, Map<String, String>> _pdfPathByBookAndGrade = <String, Map<String, String>>{};
  int _bookSeq = 0;
  String? _selectedBookId;
  int _answerKeyTabIndex = 0;
  Future<void>? _answerKeyLoadFuture;
  static const List<String> _answerKeyTabs = ['교재', '시험'];
  String get _answerKeyCategory => _answerKeyTabIndex == 0 ? 'textbook' : 'exam';
  bool get _answerKeyReadOnly => true;
  static const List<String> _answerKeyGradeOrder = [
    '초1', '초2', '초3', '초4', '초5', '초6',
    '중1', '중2', '중3',
    '고1', '고2', '고3', 'N수',
  ];

  List<_GradeOption> _grades = <_GradeOption>[];
  int _defaultGradeIndex = 0;
  int _lastGradeScrollMs = 0;
  // 책 카드에서 과정 변경(휠/드래그)이 연속으로 발생하면 서버 저장이 레이스로 꼬일 수 있어,
  // 마지막 값만 저장되도록 디바운스한다.
  final Map<String, Timer> _bookGradeSaveTimers = <String, Timer>{};
  bool _gradesLoaded = false;
  bool _gradesLoading = false;
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
    unawaited(_ensureGradesThenLoadAnswerKeyData());
  }

  Future<void> _ensureGradesThenLoadAnswerKeyData() async {
    try {
      await _loadGrades();
    } catch (_) {}
    unawaited(_loadBooks());
    unawaited(_loadPdfs());
  }

  Future<void> _loadGrades() async {
    if (_gradesLoaded || _gradesLoading) return;
    _gradesLoading = true;
    try {
      final rows = await DataManager.instance.getResourceGrades();
      final next = <_GradeOption>[];
      for (final r in rows) {
        final name = (r['name'] as String?)?.trim() ?? '';
        if (name.isEmpty) continue;
        next.add(_GradeOption(key: name, label: name));
      }
      if (!mounted) return;
      setState(() {
        _grades = next;
      });
      _gradesLoaded = true;
    } catch (_) {
      _gradesLoaded = false;
    } finally {
      _gradesLoading = false;
    }
  }

  @override
  void dispose() {
    for (final t in _bookGradeSaveTimers.values) {
      t.cancel();
    }
    _bookGradeSaveTimers.clear();
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

  List<_GradeOption> _buildGradeOptionsFromNames(Iterable<String> names) {
    final unique = names.where((e) => e.trim().isNotEmpty).map((e) => e.trim()).toSet();
    if (unique.isEmpty) return <_GradeOption>[];
    final orderIndex = <String, int>{};
    for (int i = 0; i < _answerKeyGradeOrder.length; i++) {
      orderIndex[_answerKeyGradeOrder[i]] = i;
    }
    final known = <String>[];
    final unknown = <String>[];
    for (final name in unique) {
      if (orderIndex.containsKey(name)) {
        known.add(name);
      } else {
        unknown.add(name);
      }
    }
    known.sort((a, b) => orderIndex[a]!.compareTo(orderIndex[b]!));
    unknown.sort();
    return [...known, ...unknown].map((n) => _GradeOption(key: n, label: n)).toList();
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
        // ✅ 페이지별 실제 크기를 유지 (원본과 동일한 페이지 크기/여백 방지)
        try {
          final sz = srcPage.size;
          dst.pageSettings.size = sz;
          dst.pageSettings.margins.all = 0;
        } catch (_) {}
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
    if (_booksLoaded) return;
    if (_booksLoading) {
      await (_answerKeyLoadFuture ?? Future.value());
      return;
    }
    _booksLoading = true;
    final completer = Completer<void>();
    _answerKeyLoadFuture = completer.future;
    final category = _answerKeyCategory;

    try {
      final rows = await DataManager.instance.loadResourceFilesForCategory(category);
      final nextBooks = <_BookItem>[];
      final nextPdfMap = <String, Map<String, String>>{};
      final gradeNames = <String>{};

      for (final r in rows) {
        final id = (r['id'] as String?)?.trim() ?? '';
        if (id.isEmpty) continue;
        final name = (r['name'] as String?)?.trim() ?? '';
        final desc = (r['description'] as String?)?.trim() ?? '';

        final links = await DataManager.instance.loadResourceFileLinks(id);
        final ansByGrade = <String, String>{};
        for (final e in links.entries) {
          final key = e.key.trim();
          final value = e.value.trim();
          if (key.isEmpty || value.isEmpty) continue;
          if (!key.endsWith('#ans')) continue;
          final grade = key.substring(0, key.length - 4).trim();
          if (grade.isEmpty) continue;
          ansByGrade[grade] = value;
        }
        if (ansByGrade.isEmpty) continue;
        gradeNames.addAll(ansByGrade.keys);
        nextPdfMap[id] = ansByGrade;
        nextBooks.add(_BookItem(
          id: id,
          name: name,
          description: desc,
          gradeIndex: 0,
        ));
      }

      if (!mounted || category != _answerKeyCategory) return;
      final derivedGrades = _grades.isNotEmpty ? _grades : _buildGradeOptionsFromNames(gradeNames);
      final updatedBooks = <_BookItem>[];
      for (final b in nextBooks) {
        final paths = nextPdfMap[b.id] ?? const <String, String>{};
        int gradeIndex = 0;
        if (derivedGrades.isNotEmpty) {
          final idx = derivedGrades.indexWhere((g) => paths.containsKey(g.key));
          if (idx != -1) gradeIndex = idx;
        }
        updatedBooks.add(b.copyWith(gradeIndex: gradeIndex));
      }
      setState(() {
        _books
          ..clear()
          ..addAll(updatedBooks);
        _pdfPathByBookAndGrade = nextPdfMap;
        if (_grades.isEmpty && derivedGrades.isNotEmpty) {
          _grades = derivedGrades;
          _gradesLoaded = true;
          _defaultGradeIndex = _defaultGradeIndex.clamp(0, _grades.length - 1);
        }
        if (_selectedBookId != null && !updatedBooks.any((b) => b.id == _selectedBookId)) {
          _selectedBookId = null;
        }
      });
      _booksLoaded = true;
      _pdfsLoaded = true;
    } catch (_) {
      _booksLoaded = false;
      _pdfsLoaded = false;
    } finally {
      _booksLoading = false;
      _answerKeyLoadFuture = null;
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
  }

  Future<void> _loadPdfs() async {
    if (_pdfsLoaded || _pdfsLoading) return;
    _pdfsLoading = true;
    try {
      await _loadBooks();
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
    if (_grades.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('과정이 없습니다. “과정 편집”에서 먼저 과정을 추가해주세요.')),
      );
      return;
    }

    final dlgCtx = widget.dialogContext ?? context;
    await showDialog<void>(
      context: dlgCtx,
      useRootNavigator: true,
      barrierDismissible: true,
      builder: (_) => _PdfAttachWizardDialog(
        books: _books,
        grades: _grades,
        pdfPathByBookAndGrade: _pdfPathByBookAndGrade,
        basenameOf: _basename,
        onAttach: ({
          required int bookIndex,
          required int gradeIndex,
          required XFile file,
        }) =>
            _attachPdfToBookAndGrade(
          bookIndex: bookIndex,
          gradeIndex: gradeIndex,
          file: file,
        ),
      ),
    );
  }

  Future<bool> _attachPdfToBookAndGrade({
    required int bookIndex,
    required int gradeIndex,
    required XFile file,
  }) async {
    final path = file.path.trim();
    if (path.isEmpty || !path.toLowerCase().endsWith('.pdf')) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PDF 파일만 지원합니다.')));
      }
      return false;
    }
    if (_books.isEmpty || _grades.isEmpty) return false;
    if (bookIndex < 0 || bookIndex >= _books.length) return false;
    if (gradeIndex < 0 || gradeIndex >= _grades.length) return false;

    // 선택 결과 반영(학년 포함) + uuid 정규화/서버 반영
    if (mounted) {
      setState(() {
        _books[bookIndex] = _books[bookIndex].copyWith(gradeIndex: gradeIndex);
        _defaultGradeIndex = gradeIndex;
        _selectedBookId = _books[bookIndex].id;
      });
    }
    try {
      await _saveAllBooks();
    } catch (_) {}
    if (!mounted) return false;

    final book = _books[bookIndex];
    final grade = _grades[gradeIndex];
    final existing = _pdfPathByBookAndGrade[book.id]?[grade.key];
    if (existing != null && existing.isNotEmpty && existing != path) {
      final ok = await _confirmReplacePdf(widget.dialogContext ?? context);
      if (!ok) return false;
    }

    final row = <String, dynamic>{
      'book_id': book.id,
      'grade_key': grade.key,
      'path': path,
      'name': file.name,
    };
    try {
      await DataManager.instance.saveAnswerKeyBookPdf(row);
      if (!mounted) return false;
      setState(() {
        final m = _pdfPathByBookAndGrade.putIfAbsent(book.id, () => <String, String>{});
        m[grade.key] = path;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('연결됨: ${book.name} · ${grade.label}')),
      );
      return true;
    } catch (_) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('PDF 연결 저장에 실패했습니다.')),
      );
      return false;
    }
  }

  Future<void> _openPdfForBook(_BookItem book) async {
    if (mounted) {
      setState(() => _selectedBookId = book.id);
    }
    final paths = _pdfPathByBookAndGrade[book.id];
    if (paths == null || paths.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('연결된 PDF가 없습니다: -')),
      );
      return;
    }

    if (_grades.isEmpty) {
      final entry = paths.entries.firstWhere(
        (e) => e.value.trim().isNotEmpty,
        orElse: () => const MapEntry('', ''),
      );
      if (entry.value.trim().isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('연결된 PDF가 없습니다: -')),
        );
        return;
      }
      await OpenFilex.open(entry.value);
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

  Future<void> _onEditGradesPressed() async {
    final dlgCtx = widget.dialogContext ?? context;
    final result = await showDialog<List<_GradeOption>>(
      context: dlgCtx,
      useRootNavigator: true,
      barrierDismissible: true,
      builder: (_) => _AnswerKeyGradesEditDialog(initial: _grades),
    );
    if (result == null) return;
    if (!mounted) return;
    setState(() {
      _grades = result;
      // 기본 인덱스는 범위 내로 보정
      if (_grades.isEmpty) {
        _defaultGradeIndex = 0;
      } else {
        _defaultGradeIndex = _defaultGradeIndex.clamp(0, _grades.length - 1);
      }
    });

    // 저장(서버/로컬)
    try {
      final rows = <Map<String, dynamic>>[
        for (int i = 0; i < _grades.length; i++)
          {
            'grade_key': _grades[i].key,
            'label': _grades[i].label,
            'order_index': i,
          }
      ];
      await DataManager.instance.saveAnswerKeyGrades(rows);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('과정 목록이 저장되었습니다.')));
    } catch (e) {
      if (!mounted) return;
      final s = e.toString();
      final missingTable = s.contains('answer_key_grades') &&
          (s.contains('PGRST205') || s.toLowerCase().contains('schema cache'));
      if (missingTable) {
        final localLikelySaved = !RuntimeFlags.serverOnly &&
            (!TagPresetService.preferSupabaseRead || TagPresetService.dualWrite);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              localLikelySaved
                  ? '서버 DB에 answer_key_grades 테이블이 없어 서버 저장은 실패했지만, 로컬에는 저장됐습니다. (Supabase 마이그레이션 필요)'
                  : '서버 DB에 answer_key_grades 테이블이 없어 저장할 수 없습니다. (Supabase 마이그레이션 필요)',
            ),
          ),
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('과정 목록 저장에 실패했습니다.')));
    }
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

  Future<void> _openBookPdfEditDialog(_BookItem book) async {
    if (_grades.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('과정이 없어 PDF 연결을 수정할 수 없습니다.')));
      return;
    }
    final dlgCtx = widget.dialogContext ?? context;
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

  Future<void> _onEditPdfsPressed() async {
    if (_books.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('수정할 책이 없습니다.')));
      return;
    }
    final dlgCtx = widget.dialogContext ?? context;
    final book = await _pickBookForAction(dlgCtx);
    if (book == null) return;
    await _openBookPdfEditDialog(book);
  }

  Future<void> _onEditBookPressed() async {
    if (_books.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('수정할 책이 없습니다.')));
      return;
    }
    final dlgCtx = widget.dialogContext ?? context;
    final result = await showDialog<List<_BookItem>>(
      context: dlgCtx,
      useRootNavigator: true,
      barrierDismissible: true,
      builder: (_) => _BookBulkEditDialog(
        initial: _books,
        onEditPdf: (book) => _openBookPdfEditDialog(book),
      ),
    );
    if (result == null) return;

    if (!mounted) return;
    setState(() {
      _books
        ..clear()
        ..addAll(result);
    });

    try {
      // order_index 포함 전체 저장으로 일괄 반영
      await _saveAllBooks();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('책 정보 저장에 실패했습니다.')));
    }
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
    if (_answerKeyReadOnly) return;
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
      } catch (e) {
        if (!mounted) return;
        final s = e.toString();
        final missingTable = s.contains('answer_key_books') &&
            (s.contains('PGRST205') || s.toLowerCase().contains('schema cache'));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              missingTable
                  ? '서버 DB에 answer_key_books 테이블이 없어 책 순서를 저장할 수 없습니다. (Supabase 마이그레이션 필요)'
                  : '책 순서 저장에 실패했습니다.',
            ),
          ),
        );
      }
    }());
  }

  // NOTE: 기존(초/중/고 고정 학년 목록)은 사용하지 않음.
  // 과정(=학년/레벨) 목록은 `answer_key_grades` 테이블에서 로드/편집한다.

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

  void _schedulePersistBookGrade(String bookId) {
    _bookGradeSaveTimers[bookId]?.cancel();
    _bookGradeSaveTimers[bookId] = Timer(const Duration(milliseconds: 320), () {
      _bookGradeSaveTimers.remove(bookId);
      final idx = _books.indexWhere((b) => b.id == bookId);
      if (idx == -1) return;
      unawaited(() async {
        try {
          final b0 = _books[idx];
          var b = b0;
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
    });
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

    if (!_answerKeyReadOnly) {
      // ✅ 마지막 선택만 저장되도록 디바운스
      _schedulePersistBookGrade(bookId);
    }
  }

  void _onAnswerKeyTabSelected(int idx) {
    if (idx == _answerKeyTabIndex) return;
    setState(() {
      _answerKeyTabIndex = idx;
      _books.clear();
      _pdfPathByBookAndGrade = <String, Map<String, String>>{};
      _selectedBookId = null;
      _booksLoaded = false;
      _pdfsLoaded = false;
      _booksLoading = false;
      _pdfsLoading = false;
    });
    _answerKeyLoadFuture = null;
    unawaited(_ensureGradesThenLoadAnswerKeyData());
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
                    unawaited(_ensureGradesThenLoadAnswerKeyData());
                  }
                  if (m == RightSideSheetMode.memo) {
                    unawaited(DataManager.instance.loadMemos());
                  }
                },
                onClose: widget.onClose,
              ),
              const Divider(height: 1, color: Color(0x22FFFFFF)),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    switch (_mode) {
      case RightSideSheetMode.answerKey:
        // grades는 답지 기능의 핵심 의존성이라, 최초 진입 시 지연 로드 보장
        if (!_gradesLoaded && !_gradesLoading) {
          unawaited(_loadGrades());
        }
        return _AnswerKeyPdfShortcutExplorer(
          tabIndex: _answerKeyTabIndex,
          onTabSelected: _onAnswerKeyTabSelected,
          books: _books,
          grades: _grades,
          pdfPathByBookAndGrade: _pdfPathByBookAndGrade,
          onAddBook: _openAddBookDialog,
          onEditBook: () => unawaited(_onEditBookPressed()),
          onBookGradeDelta: ({required String bookId, required int delta}) =>
              _changeBookGradeByDelta(bookId: bookId, delta: delta),
          onOpenBook: (book) => unawaited(_openPdfForBook(book)),
          onReorderBooks: _onReorderBooks,
          onEditGrades: () => unawaited(_onEditGradesPressed()),
          onDeleteBook: () => unawaited(_onDeleteBookPressed()),
          onSelectBook: (id) => setState(() => _selectedBookId = id),
        );
      case RightSideSheetMode.memo:
        return _MemoExplorer(
          memosListenable: DataManager.instance.memosNotifier,
          onAddMemo: () => unawaited(_onAddMemoPressed()),
          onEditMemo: (m) => unawaited(_onEditMemoPressed(m)),
          selectedFilterKey: _memoFilterKey,
          onFilterChanged: (k) => setState(() => _memoFilterKey = k),
          onOpenConsult: () => unawaited(_openConsultPage()),
          onCloseSheet: widget.onClose,
        );
      case RightSideSheetMode.fileShortcut:
        return FileShortcutTab(dialogContext: widget.dialogContext);
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
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 140),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeOutCubic,
                transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
                child: hasPdf
                    ? SizedBox(
                        key: const ValueKey('pdf_edit_preview_btn'),
                        height: 48,
                        child: OutlinedButton.icon(
                          onPressed: _pdfEditBusy ? null : _openPdfPreviewSelectDialogFromSheet,
                          icon: const Icon(Icons.preview_outlined, size: 16),
                          label: const Text('미리보기로 편집'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _rsTextSub,
                            side: const BorderSide(color: _rsBorder),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      )
                    : const SizedBox(
                        key: ValueKey('pdf_edit_preview_btn_empty'),
                        height: 48,
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
    final initialCat = (_memoFilterKey == MemoCategory.schedule || _memoFilterKey == MemoCategory.consult)
        ? _memoFilterKey
        : MemoCategory.schedule;
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
    final String pickedCategoryKey = result.categoryKey;
    final memo = Memo(
      id: const Uuid().v4(),
      original: trimmed,
      summary: '요약 중...',
      scheduledAt: await AiSummaryService.extractDateTime(trimmed),
      categoryKey: MemoCategory.normalize(pickedCategoryKey),
      dismissed: false,
      createdAt: now,
      updatedAt: now,
    );
    await DataManager.instance.addMemo(memo);

    try {
      final summary = await AiSummaryService.summarize(memo.original);
      await DataManager.instance.updateMemo(
        memo.copyWith(
          summary: summary,
          updatedAt: DateTime.now(),
        ),
      );
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
      // 문의 노트로 진입할 때는 우측 사이드 시트를 닫는다.
      // (닫힌 상태에서 별도 패널로 문의 노트를 사용하는 UX)
      final nav = Navigator.of(ctx, rootNavigator: true);
      try {
        widget.onClose();
      } catch (_) {}
      await nav.push(
        DarkPanelRoute<void>(child: const ConsultNotesScreen()),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('문의 노트 페이지를 열 수 없습니다.')));
      }
    }
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
  final VoidCallback onCloseSheet;

  const _MemoExplorer({
    required this.memosListenable,
    required this.onAddMemo,
    required this.onEditMemo,
    required this.selectedFilterKey,
    required this.onFilterChanged,
    required this.onOpenConsult,
    required this.onCloseSheet,
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
                  tooltip: '문의 노트 열기',
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
                var list = [...memos]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
                if (selectedFilterKey != _RightSideSheetState._memoFilterAll) {
                  list = list.where((m) => m.categoryKey == selectedFilterKey).toList();
                }

                // 문의 탭에서는: 등록 문의(필기 노트) 목록만 제공 (문의 메모 리스트는 제거)
                if (selectedFilterKey == MemoCategory.inquiry) {
                  return FutureBuilder<List<ConsultNoteMeta>>(
                    future: ConsultNoteService.instance.listMetas(),
                    builder: (context, snap) {
                      final notes = snap.data ?? const <ConsultNoteMeta>[];
                      if (notes.isEmpty) {
                        return const Center(
                          child: Text('등록 문의 없음', style: TextStyle(color: _rsTextSub, fontSize: 13, fontWeight: FontWeight.w700)),
                        );
                      }

                      final items = <Widget>[];
                      if (notes.isNotEmpty) {
                        items.add(const Padding(
                          padding: EdgeInsets.fromLTRB(2, 6, 2, 8),
                          child: Text('등록 문의', style: TextStyle(color: _rsTextSub, fontSize: 12, fontWeight: FontWeight.w900)),
                        ));
                        items.add(ValueListenableBuilder<List<ConsultTrialLessonSlot>>(
                          valueListenable: ConsultTrialLessonService.instance.slotsNotifier,
                          builder: (context, trialSlots, _) {
                            final trialNoteIds = trialSlots
                                .map((s) => s.sourceNoteId)
                                .where((id) => id.isNotEmpty)
                                .toSet();
                            final arrivedNoteIds = trialSlots
                                .where((s) => s.arrivalTime != null)
                                .map((s) => s.sourceNoteId)
                                .where((id) => id.isNotEmpty)
                                .toSet();

                            final children = <Widget>[];
                            for (final n in notes) {
                              final dt = n.updatedAt.toLocal();
                              final hh = dt.hour.toString().padLeft(2, '0');
                              final mm = dt.minute.toString().padLeft(2, '0');
                              final subtitle = '${dt.month}/${dt.day} $hh:$mm · 선 ${n.strokeCount}개';

                              final bool hasDesired = n.desiredWeekday != null && n.desiredHour != null && n.desiredMinute != null;
                              final bool hasTrial = trialNoteIds.contains(n.id);
                              final bool hasArrived = arrivedNoteIds.contains(n.id);
                              final int stage = (hasArrived && hasDesired) ? 3 : (hasTrial ? 2 : 1);

                              children.add(_InquiryNoteCard(
                                key: ValueKey('note:${n.id}'),
                                title: n.title,
                                subtitle: subtitle,
                                stage: stage,
                                onTap: () {
                                  ConsultNoteController.instance.requestOpen(n.id);
                                  // 문의 노트 화면이 열려있지 않으면 먼저 열어준다(중복 push 방지)
                                  if (!ConsultNoteController.instance.isScreenOpen) {
                                    onOpenConsult();
                                  } else {
                                    onCloseSheet();
                                  }
                                },
                                onDelete: () {
                                  unawaited(() async {
                                    await ConsultNoteService.instance.delete(n.id);
                                    await ConsultInquiryDemandService.instance.removeForNote(n.id);
                                    await ConsultTrialLessonService.instance.removeForNote(n.id);
                                    // 동일 탭으로 setState 유도(노트 목록 갱신)
                                    onFilterChanged(selectedFilterKey);
                                  }());
                                },
                              ));
                              children.add(const SizedBox(height: 10));
                            }
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: children,
                            );
                          },
                        ));
                      }

                      return ListView(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        children: items,
                      );
                    },
                  );
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

class _MemoCard extends StatefulWidget {
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
  State<_MemoCard> createState() => _MemoCardState();
}

class _InquiryNoteCard extends StatefulWidget {
  final String title;
  final String subtitle;
  /// 문의 노트 진행 단계:
  /// 1 = 상담/문의 생성
  /// 2 = 시범수업 완료
  /// 3 = 시범수업 + 희망수업 기록(등록 직전)
  final int stage;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _InquiryNoteCard({
    super.key,
    required this.title,
    required this.subtitle,
    this.stage = 1,
    required this.onTap,
    required this.onDelete,
  });

  @override
  State<_InquiryNoteCard> createState() => _InquiryNoteCardState();
}

class _InquiryNoteCardState extends State<_InquiryNoteCard> with SingleTickerProviderStateMixin {
  // 메모 카드와 동일한 슬라이드 삭제 UX
  // 단일 삭제 액션은 2버튼(140) 기준 "1버튼 분량"만 차지하도록 축소
  static const double _actionPaneWidth = 74;
  static const double _minCardHeight = 84;
  static const Duration _snapDuration = Duration(milliseconds: 160);

  late final AnimationController _ctrl = AnimationController(vsync: this, duration: _snapDuration);

  bool get _isOpen => _ctrl.value > 0.01;

  void _open() => _ctrl.animateTo(1, curve: Curves.easeOutCubic);
  void _close() => _ctrl.animateTo(0, curve: Curves.easeOutCubic);

  void _handleHorizontalDragUpdate(DragUpdateDetails d) {
    final next = _ctrl.value + (-d.delta.dx / _actionPaneWidth);
    _ctrl.value = next.clamp(0.0, 1.0);
  }

  void _handleHorizontalDragEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0.0;
    if (v < -250) {
      _open();
      return;
    }
    if (v > 250) {
      _close();
      return;
    }
    if (_ctrl.value >= 0.5) {
      _open();
    } else {
      _close();
    }
  }

  void _handleTapFront() {
    if (_isOpen) {
      _close();
      return;
    }
    widget.onTap();
  }

  void _handleDelete() {
    _ctrl.value = 0;
    widget.onDelete();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(14);

    Color stageColor(int stage) {
      switch (stage) {
        case 3:
          return _rsAccent;
        case 2:
          return const Color(0xFFF2B45B); // 예정(노랑)
        default:
          return _rsTextSub;
      }
    }

    String stageLabel(int stage) {
      switch (stage) {
        case 3:
          return '3대기';
        case 2:
          return '2예정';
        default:
          return '1문의';
      }
    }

    Widget frontCard() {
      return ConstrainedBox(
        constraints: const BoxConstraints(minHeight: _minCardHeight),
        child: Material(
          color: _rsFieldBg,
          child: InkWell(
            onTap: _handleTapFront,
            borderRadius: radius,
            splashFactory: NoSplash.splashFactory,
            highlightColor: Colors.white.withOpacity(0.05),
            hoverColor: Colors.white.withOpacity(0.03),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: _rsText, fontSize: 14, fontWeight: FontWeight.w900),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          widget.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: _rsTextSub, fontSize: 12, fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: stageColor(widget.stage).withOpacity(0.14),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: stageColor(widget.stage).withOpacity(0.28)),
                    ),
                    child: Text(
                      stageLabel(widget.stage),
                      style: TextStyle(
                        color: stageColor(widget.stage),
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
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

    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onHorizontalDragUpdate: _handleHorizontalDragUpdate,
        onHorizontalDragEnd: _handleHorizontalDragEnd,
        onHorizontalDragCancel: _close,
        child: Container(
          constraints: const BoxConstraints(minHeight: _minCardHeight),
          decoration: BoxDecoration(
            color: _rsFieldBg,
            borderRadius: radius,
            border: Border.all(color: _rsBorder.withOpacity(0.9)),
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: Stack(
              children: [
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  width: _actionPaneWidth,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Material(
                      color: const Color(0xFFB74C4C),
                      borderRadius: BorderRadius.circular(10),
                      child: InkWell(
                        onTap: _handleDelete,
                        borderRadius: BorderRadius.circular(10),
                        splashFactory: NoSplash.splashFactory,
                        highlightColor: Colors.white.withOpacity(0.08),
                        hoverColor: Colors.white.withOpacity(0.04),
                        child: const SizedBox.expand(
                          child: Center(
                            child: Icon(Icons.delete_outline_rounded, size: 18, color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                AnimatedBuilder(
                  animation: _ctrl,
                  builder: (context, child) {
                    final dx = -_actionPaneWidth * _ctrl.value;
                    return Transform.translate(offset: Offset(dx, 0), child: child);
                  },
                  child: frontCard(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MemoCardState extends State<_MemoCard> with SingleTickerProviderStateMixin {
  // 삭제 액션 패널 너비를 30% 축소 (108 -> 75.6)
  // 단일 삭제 액션은 2버튼(140) 기준 "1버튼 분량"만 차지하도록 축소
  static const double _actionPaneWidth = 74;
  static const double _minCardHeight = 96;
  static const Duration _snapDuration = Duration(milliseconds: 160);

  late final AnimationController _ctrl = AnimationController(vsync: this, duration: _snapDuration);

  bool get _isOpen => _ctrl.value > 0.01;

  void _open() => _ctrl.animateTo(1, curve: Curves.easeOutCubic);
  void _close() => _ctrl.animateTo(0, curve: Curves.easeOutCubic);

  void _handleHorizontalDragUpdate(DragUpdateDetails d) {
    // 왼쪽으로 드래그(delta.dx < 0)하면 열림 진행도(value)가 증가한다.
    final next = _ctrl.value + (-d.delta.dx / _actionPaneWidth);
    _ctrl.value = next.clamp(0.0, 1.0);
  }

  void _handleHorizontalDragEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0.0; // +: 오른쪽, -: 왼쪽
    if (v < -250) {
      _open();
      return;
    }
    if (v > 250) {
      _close();
      return;
    }
    if (_ctrl.value >= 0.5) {
      _open();
    } else {
      _close();
    }
  }

  void _handleTapFront() {
    // 액션 패널이 열려 있으면 탭은 닫기 동작으로 처리한다.
    if (_isOpen) {
      _close();
      return;
    }
    widget.onTap();
  }

  void _handleDelete() {
    _ctrl.value = 0;
    widget.onDelete();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(14);

    Widget frontCard() {
      // Stack의 non-positioned child는 loosened constraints를 받기 때문에,
      // 최소 높이를 직접 강제해서(삭제 액션 영역이 항상 확보되게) 버튼 비침/오버플로우를 방지한다.
      return ConstrainedBox(
        constraints: const BoxConstraints(minHeight: _minCardHeight),
        child: Material(
          color: _rsFieldBg,
          child: InkWell(
            onTap: _handleTapFront,
            borderRadius: radius,
            splashFactory: NoSplash.splashFactory,
            highlightColor: Colors.white.withOpacity(0.05),
            hoverColor: Colors.white.withOpacity(0.03),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Text(
                              widget.dateLabel,
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
                                widget.categoryLabel,
                                style: const TextStyle(color: _rsTextSub, fontSize: 11, fontWeight: FontWeight.w900),
                              ),
                            ),
                            if (widget.scheduleLabel.isNotEmpty) ...[
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  '· ${widget.scheduleLabel}',
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
                    widget.text,
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _rsText, fontSize: 14, fontWeight: FontWeight.w800, height: 1.3),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onHorizontalDragUpdate: _handleHorizontalDragUpdate,
        onHorizontalDragEnd: _handleHorizontalDragEnd,
        onHorizontalDragCancel: _close,
        child: Container(
          constraints: const BoxConstraints(minHeight: _minCardHeight),
          decoration: BoxDecoration(
            color: _rsFieldBg,
            borderRadius: radius,
            border: Border.all(color: _rsBorder.withOpacity(0.9)),
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: Stack(
              children: [
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  width: _actionPaneWidth,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Material(
                      color: const Color(0xFFB74C4C),
                      borderRadius: BorderRadius.circular(10),
                      child: InkWell(
                        onTap: _handleDelete,
                        borderRadius: BorderRadius.circular(10),
                        splashFactory: NoSplash.splashFactory,
                        highlightColor: Colors.white.withOpacity(0.08),
                        hoverColor: Colors.white.withOpacity(0.04),
                        child: const SizedBox.expand(
                          child: Center(
                            child: Icon(Icons.delete_outline_rounded, size: 18, color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // Stack에 non-positioned child가 있어야(높이 제약이 무한대일 때) RenderStack이 정상적으로 크기를 계산한다.
                AnimatedBuilder(
                  animation: _ctrl,
                  builder: (context, child) {
                    final dx = -_actionPaneWidth * _ctrl.value;
                    return Transform.translate(offset: Offset(dx, 0), child: child);
                  },
                  child: frontCard(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

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
  final int tabIndex;
  final ValueChanged<int> onTabSelected;
  final List<_BookItem> books;
  final List<_GradeOption> grades;
  final Map<String, Map<String, String>> pdfPathByBookAndGrade;
  final VoidCallback onAddBook;
  final VoidCallback onEditBook;
  final VoidCallback onEditGrades;
  final VoidCallback onDeleteBook;
  final void Function(String bookId) onSelectBook;
  final void Function({required String bookId, required int delta}) onBookGradeDelta;
  final void Function(_BookItem book) onOpenBook;
  final void Function(int oldIndex, int newIndex) onReorderBooks;

  const _AnswerKeyPdfShortcutExplorer({
    required this.tabIndex,
    required this.onTabSelected,
    required this.books,
    required this.grades,
    required this.pdfPathByBookAndGrade,
    required this.onAddBook,
    required this.onEditBook,
    required this.onEditGrades,
    required this.onDeleteBook,
    required this.onSelectBook,
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
          Center(
            child: PillTabSelector(
              selectedIndex: widget.tabIndex,
              tabs: _RightSideSheetState._answerKeyTabs,
              onTabSelected: widget.onTabSelected,
              width: 220,
              height: 36,
              fontSize: 14,
              padding: 3,
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _BooksSection(
              books: widget.books,
              grades: widget.grades,
              pdfPathByBookAndGrade: widget.pdfPathByBookAndGrade,
              onBookGradeDelta: widget.onBookGradeDelta,
              onOpenBook: widget.onOpenBook,
              onReorderBooks: widget.onReorderBooks,
              onSelectBook: widget.onSelectBook,
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
    final hasLeading = leading != null;
    final hasTrailing = trailing != null;
    return Container(
      decoration: BoxDecoration(
        color: _rsPanelBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _rsBorder),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        children: [
          if (hasLeading) Expanded(child: leading!) else const Spacer(),
          if (hasTrailing) ...[
            if (hasLeading) const SizedBox(width: 6),
            trailing!,
          ],
        ],
      ),
    );
  }
}

class _ToolbarSegmentButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool showRightDivider;

  const _ToolbarSegmentButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    required this.showRightDivider,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final iconColor = enabled ? Colors.white70 : Colors.white24;
    final border = showRightDivider ? Border(right: BorderSide(color: _rsBorder.withOpacity(0.9))) : null;

    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 450),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          child: Container(
            height: 44,
            decoration: BoxDecoration(border: border),
            child: Center(
              child: Icon(icon, size: 20, color: iconColor),
            ),
          ),
        ),
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
  final void Function(String bookId) onSelectBook;
  final ScrollController scrollController;
  const _BooksSection({
    required this.books,
    required this.grades,
    required this.pdfPathByBookAndGrade,
    required this.onBookGradeDelta,
    required this.onOpenBook,
    required this.onReorderBooks,
    required this.onSelectBook,
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
                        onOpen: () {
                          onSelectBook(b.id);
                          onOpenBook(b);
                        },
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

class _BookCard extends StatefulWidget {
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
  State<_BookCard> createState() => _BookCardState();
}

class _BookCardState extends State<_BookCard> {
  double _gradeDragDx = 0.0;

  void _handleGradeDragUpdate(DragUpdateDetails d) {
    _gradeDragDx += d.delta.dx;
    if (_gradeDragDx <= -48) {
      _gradeDragDx = 0.0;
      widget.onGradeDelta(-1);
    } else if (_gradeDragDx >= 48) {
      _gradeDragDx = 0.0;
      widget.onGradeDelta(1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(14);

    Widget buildGradeBadge() {
      final bg = widget.linked ? _rsPanelBg : _rsPanelBg.withOpacity(0.35);
      final fg = widget.linked ? _rsTextSub : Colors.white24;
      return SizedBox(
        height: 30,
        // NOTE: ReorderableListView 내부에서 Tooltip(OverlayPortal)이 레이아웃 중 attach되며
        // "A _RenderLayoutBuilder was mutated" 에러가 발생하는 케이스가 있어,
        // 여기서는 Tooltip을 사용하지 않는다. (긴 과정명은 ellipsis로 처리)
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (_) => _gradeDragDx = 0.0,
          onHorizontalDragUpdate: _handleGradeDragUpdate,
          onHorizontalDragEnd: (_) => _gradeDragDx = 0.0,
          onHorizontalDragCancel: () => _gradeDragDx = 0.0,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.transparent),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Align(
                alignment: Alignment.centerRight,
                child: Text(
                  widget.gradeLabel,
                  style: TextStyle(color: fg, fontSize: 13, fontWeight: FontWeight.w900),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  textAlign: TextAlign.right,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerSignal: (signal) {
          if (signal is PointerScrollEvent) {
            final dx = signal.scrollDelta.dx;
            final dy = signal.scrollDelta.dy;
            // 수직 스크롤은 리스트 스크롤에 맡기고, 가로 입력만 과정 변경으로 사용
            if (dx != 0 && dx.abs() >= dy.abs()) {
              // 요청: 왼쪽(음수)=내려감(-1), 오른쪽(양수)=올라감(+1)
              widget.onGradeDelta(dx < 0 ? -1 : 1);
            }
          }
        },
        child: Material(
          color: _rsFieldBg,
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: BorderSide(color: _rsBorder.withOpacity(0.9)),
          ),
          child: InkWell(
            onTap: widget.onOpen,
            borderRadius: radius,
            splashFactory: NoSplash.splashFactory,
            highlightColor: Colors.white.withOpacity(0.05),
            hoverColor: Colors.white.withOpacity(0.03),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.item.name,
                          style: const TextStyle(color: _rsText, fontSize: 16, fontWeight: FontWeight.w900),
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 10),
                      // 요구사항: 이름:과정라벨 = 1:1
                      Expanded(child: buildGradeBadge()),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.item.description,
                    style: const TextStyle(color: _rsTextSub, fontSize: 13, fontWeight: FontWeight.w600, height: 1.25),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
        ),
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
            '연결된 정답 PDF가 없습니다.',
            style: TextStyle(color: _rsTextSub, fontSize: 12, fontWeight: FontWeight.w800),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: 6),
          Text(
            '교재 탭에서 정답 링크를 등록하면 여기서 바로 열 수 있습니다.',
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
  final String key;
  final String label;
  const _GradeOption({required this.key, required this.label});
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
      width: 96,
      height: 30,
      child: PopupMenuButton<int>(
        tooltip: '과정 선택',
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
        child: Tooltip(
          message: label,
          waitDuration: const Duration(milliseconds: 450),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: _rsPanelBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.transparent),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: const TextStyle(color: _rsTextSub, fontSize: 13, fontWeight: FontWeight.w900),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    ),
                  ),
                  const SizedBox(width: 2),
                  const Icon(Icons.keyboard_arrow_down, size: 16, color: _rsTextSub),
                ],
              ),
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

class _AnswerKeyGradesEditDialog extends StatefulWidget {
  final List<_GradeOption> initial;
  const _AnswerKeyGradesEditDialog({required this.initial});

  @override
  State<_AnswerKeyGradesEditDialog> createState() => _AnswerKeyGradesEditDialogState();
}

class _AnswerKeyGradesEditDialogState extends State<_AnswerKeyGradesEditDialog> {
  final List<TextEditingController> _ctrls = <TextEditingController>[];
  final List<String> _keys = <String>[];
  final ScrollController _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    for (final g in widget.initial) {
      _keys.add(g.key);
      _ctrls.add(ImeAwareTextEditingController(text: g.label));
    }
    if (_keys.isEmpty) {
      // 초기 항목이 없으면 1개를 기본으로 제공
      _keys.add(const Uuid().v4());
      _ctrls.add(ImeAwareTextEditingController(text: ''));
    }
  }

  @override
  void dispose() {
    for (final c in _ctrls) {
      c.dispose();
    }
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _addRow() {
    setState(() {
      _keys.add(const Uuid().v4());
      _ctrls.add(ImeAwareTextEditingController(text: ''));
    });
  }

  void _removeRow(int index) {
    if (index < 0 || index >= _keys.length) return;
    setState(() {
      _ctrls[index].dispose();
      _ctrls.removeAt(index);
      _keys.removeAt(index);
      if (_keys.isEmpty) {
        _keys.add(const Uuid().v4());
        _ctrls.add(ImeAwareTextEditingController(text: ''));
      }
    });
  }

  void _save() {
    final out = <_GradeOption>[];
    final seen = <String>{};
    for (int i = 0; i < _keys.length; i++) {
      final label = _ctrls[i].text.trim();
      if (label.isEmpty) continue;
      if (seen.contains(label)) continue;
      seen.add(label);
      out.add(_GradeOption(key: _keys[i], label: label));
    }
    Navigator.of(context).pop<List<_GradeOption>>(out);
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
        '과정 편집',
        style: TextStyle(color: _rsText, fontSize: 18, fontWeight: FontWeight.w900),
      ),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '여기에 과정명을 입력하세요. (예: 기본, 심화, 내신, 수능)\n빈 항목은 저장 시 제외됩니다.',
              style: TextStyle(color: _rsTextSub, fontSize: 12, fontWeight: FontWeight.w700, height: 1.35),
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: Scrollbar(
                controller: _scrollCtrl,
                thumbVisibility: true,
                child: ReorderableListView.builder(
                  scrollController: _scrollCtrl,
                  shrinkWrap: true,
                  itemCount: _keys.length,
                  buildDefaultDragHandles: false,
                  onReorder: (oldIndex, newIndex) {
                    setState(() {
                      final oi = oldIndex;
                      final ni = newIndex > oldIndex ? newIndex - 1 : newIndex;
                      final k = _keys.removeAt(oi);
                      final c = _ctrls.removeAt(oi);
                      _keys.insert(ni, k);
                      _ctrls.insert(ni, c);
                    });
                  },
                  itemBuilder: (context, index) {
                    return Container(
                      key: ValueKey(_keys[index]),
                      margin: EdgeInsets.only(bottom: index == _keys.length - 1 ? 0 : 8),
                      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                      decoration: BoxDecoration(
                        color: _rsFieldBg,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: _rsBorder.withOpacity(0.9)),
                      ),
                      child: Row(
                        children: [
                          ReorderableDragStartListener(
                            index: index,
                            child: const Icon(Icons.drag_indicator, color: Colors.white24, size: 18),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: _ctrls[index],
                              style: const TextStyle(color: _rsText, fontWeight: FontWeight.w800),
                              decoration: const InputDecoration(
                                isDense: true,
                                border: InputBorder.none,
                                hintText: '과정명',
                                hintStyle: TextStyle(color: Colors.white24),
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '삭제',
                            onPressed: () => _removeRow(index),
                            icon: const Icon(Icons.close, color: Colors.white38, size: 18),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _addRow,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('추가'),
                style: TextButton.styleFrom(foregroundColor: _rsTextSub),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop<List<_GradeOption>?>(null),
          style: TextButton.styleFrom(foregroundColor: _rsTextSub),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _save,
          style: FilledButton.styleFrom(
            backgroundColor: _rsAccent,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: const Text('저장', style: TextStyle(fontWeight: FontWeight.w900)),
        ),
      ],
    );
  }
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
  final ScrollController _scrollCtrl = ScrollController();

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
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final maxH = (MediaQuery.of(context).size.height * 0.78).clamp(360.0, 620.0).toDouble();
    final desiredH = 160.0 + (widget.grades.length * 116.0);
    final bodyHeight = desiredH.clamp(320.0, maxH).toDouble();

    Widget statusPill({required bool linked}) {
      final Color color = linked ? _rsAccent : _rsTextSub;
      final String label = linked ? '연결됨' : '미연결';
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withOpacity(0.14),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withOpacity(0.28)),
        ),
        child: Text(
          label,
          style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w900, height: 1.0),
        ),
      );
    }

    return AlertDialog(
      backgroundColor: _rsBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: _rsBorder),
      ),
      titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
      contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('PDF 수정', style: TextStyle(color: _rsText, fontSize: 18, fontWeight: FontWeight.w900)),
          const SizedBox(height: 6),
          Text(
            widget.book.name,
            style: const TextStyle(color: _rsTextSub, fontSize: 13, fontWeight: FontWeight.w800),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      content: SizedBox(
        width: 600,
        height: bodyHeight,
        child: Scrollbar(
          controller: _scrollCtrl,
          thumbVisibility: true,
          child: ListView.separated(
            controller: _scrollCtrl,
            padding: const EdgeInsets.only(top: 8),
            itemCount: widget.grades.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final g = widget.grades[i];
              final path = _paths[g.key];
              final linked = path != null && path.trim().isNotEmpty;
              final fileLabel = linked ? widget.basenameOf(path) : '미연결';

              final outlinedStyle = OutlinedButton.styleFrom(
                foregroundColor: Colors.white70,
                side: BorderSide(color: _rsBorder.withOpacity(0.9)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: 12),
              );

              return Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: _rsFieldBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _rsBorder.withOpacity(0.9)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          // ✅ 과정명은 잘리지 않게: 전체 폭을 쓰고 자연스럽게 줄바꿈
                          child: Text(
                            g.label,
                            style: TextStyle(
                              color: linked ? _rsText : _rsTextSub,
                              fontSize: 14,
                              fontWeight: FontWeight.w900,
                              height: 1.15,
                            ),
                            softWrap: true,
                          ),
                        ),
                        const SizedBox(width: 10),
                        statusPill(linked: linked),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(
                          Icons.picture_as_pdf_outlined,
                          size: 16,
                          color: linked ? _rsTextSub : Colors.white24,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Tooltip(
                            message: linked ? path! : '미연결',
                            waitDuration: const Duration(milliseconds: 450),
                            child: Text(
                              fileLabel,
                              style: TextStyle(
                                color: linked ? _rsText : _rsTextSub,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                              softWrap: false,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (linked) ...[
                          OutlinedButton.icon(
                            onPressed: _busy ? null : () => _open(path!),
                            style: outlinedStyle,
                            icon: const Icon(Icons.open_in_new, size: 16),
                            label: const Text('열기'),
                          ),
                          const SizedBox(width: 8),
                        ],
                        OutlinedButton.icon(
                          onPressed: _busy ? null : () => _pickAndSet(g),
                          style: outlinedStyle,
                          icon: const Icon(Icons.folder_open, size: 16),
                          label: Text(linked ? '변경' : '연결'),
                        ),
                        if (linked) ...[
                          const SizedBox(width: 8),
                          TextButton.icon(
                            onPressed: (!_busy && linked) ? () => _detach(g) : null,
                            style: TextButton.styleFrom(
                              foregroundColor: const Color(0xFFFFB4B4),
                              minimumSize: const Size(0, 36),
                              padding: const EdgeInsets.symmetric(horizontal: 10),
                            ),
                            icon: const Icon(Icons.link_off, size: 16),
                            label: const Text('해제'),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
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

class _BookBulkEditDialog extends StatefulWidget {
  final List<_BookItem> initial;
  final Future<void> Function(_BookItem book)? onEditPdf;
  const _BookBulkEditDialog({required this.initial, this.onEditPdf});

  @override
  State<_BookBulkEditDialog> createState() => _BookBulkEditDialogState();
}

class _BookBulkEditDialogState extends State<_BookBulkEditDialog> {
  late final List<TextEditingController> _nameCtrls = <TextEditingController>[
    for (final b in widget.initial) ImeAwareTextEditingController(text: b.name),
  ];
  late final List<TextEditingController> _descCtrls = <TextEditingController>[
    for (final b in widget.initial) ImeAwareTextEditingController(text: b.description),
  ];
  final ScrollController _scrollCtrl = ScrollController();

  @override
  void dispose() {
    for (final c in _nameCtrls) {
      c.dispose();
    }
    for (final c in _descCtrls) {
      c.dispose();
    }
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final updated = <_BookItem>[];
    for (int i = 0; i < widget.initial.length; i++) {
      final name = _nameCtrls[i].text.trim();
      final desc = _descCtrls[i].text.trim();
      if (name.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('책 이름은 비워둘 수 없습니다.')));
        return;
      }
      updated.add(widget.initial[i].copyWith(name: name, description: desc));
    }
    Navigator.of(context).pop<List<_BookItem>>(updated);
  }

  InputDecoration _fieldDeco(String label) => InputDecoration(
        labelText: label,
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
      );

  Widget _indexPill(int index) {
    return SizedBox(
      height: 28,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _rsPanelBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _rsBorder.withOpacity(0.9)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Center(
            child: Text(
              '${index + 1}',
              style: const TextStyle(color: _rsTextSub, fontSize: 12, fontWeight: FontWeight.w900),
            ),
          ),
        ),
      ),
    );
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
        '책 수정',
        style: TextStyle(color: _rsText, fontSize: 18, fontWeight: FontWeight.w900),
      ),
      content: SizedBox(
        width: 620 * 0.7,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Divider(height: 1, color: Color(0x22FFFFFF)),
            const SizedBox(height: 12),
            Expanded(
              child: Scrollbar(
                controller: _scrollCtrl,
                thumbVisibility: true,
                child: ListView.separated(
                  controller: _scrollCtrl,
                  itemCount: widget.initial.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    return Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: _rsFieldBg,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: _rsBorder.withOpacity(0.9)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              _indexPill(index),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  '이름 / 설명',
                                  style: const TextStyle(color: _rsTextSub, fontSize: 12, fontWeight: FontWeight.w800),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              OutlinedButton.icon(
                                onPressed: widget.onEditPdf == null
                                    ? null
                                    : () {
                                        final b0 = widget.initial[index];
                                        final name = _nameCtrls[index].text.trim();
                                        final desc = _descCtrls[index].text.trim();
                                        final book = b0.copyWith(
                                          name: name.isNotEmpty ? name : b0.name,
                                          description: desc,
                                        );
                                        unawaited(widget.onEditPdf!(book));
                                      },
                                icon: const Icon(Icons.picture_as_pdf_outlined, size: 16),
                                label: const Text('PDF 수정'),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.white70,
                                  side: BorderSide(color: _rsBorder.withOpacity(0.9)),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  minimumSize: const Size(0, 32),
                                  padding: const EdgeInsets.symmetric(horizontal: 10),
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  visualDensity: VisualDensity.compact,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _nameCtrls[index],
                            style: const TextStyle(color: _rsText, fontWeight: FontWeight.w800),
                            decoration: _fieldDeco('책 이름'),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: _descCtrls[index],
                            maxLines: 1,
                            style: const TextStyle(color: _rsText),
                            decoration: _fieldDeco('설명'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop<List<_BookItem>?>(null),
          style: TextButton.styleFrom(foregroundColor: _rsTextSub),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _submit,
          style: FilledButton.styleFrom(
            backgroundColor: _rsAccent,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: const Text('저장', style: TextStyle(fontWeight: FontWeight.w900)),
        ),
      ],
    );
  }
}

class _PdfAttachWizardDialog extends StatefulWidget {
  final List<_BookItem> books;
  final List<_GradeOption> grades;
  final Map<String, Map<String, String>> pdfPathByBookAndGrade;
  final String Function(String path) basenameOf;
  final Future<bool> Function({
    required int bookIndex,
    required int gradeIndex,
    required XFile file,
  }) onAttach;

  const _PdfAttachWizardDialog({
    required this.books,
    required this.grades,
    required this.pdfPathByBookAndGrade,
    required this.basenameOf,
    required this.onAttach,
  });

  @override
  State<_PdfAttachWizardDialog> createState() => _PdfAttachWizardDialogState();
}

class _PdfAttachWizardDialogState extends State<_PdfAttachWizardDialog> {
  final ScrollController _scrollCtrl = ScrollController();
  int _step = 0; // 0=책 선택, 1=과정 선택
  int? _bookIndex;
  bool _busy = false;
  final Map<int, XFile> _pendingByGradeIndex = <int, XFile>{}; // key=gradeIndex

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<XFile?> _pickPdf() async {
    final typeGroup = XTypeGroup(label: 'PDF', extensions: const ['pdf']);
    return await openFile(acceptedTypeGroups: [typeGroup]);
  }

  bool _isPdf(XFile f) => f.path.trim().toLowerCase().endsWith('.pdf');

  Widget _outlinedAction({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white70,
        side: BorderSide(color: _rsBorder.withOpacity(0.9)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 12),
      ),
    );
  }

  Widget _dropButton({
    required Future<void> Function(XFile f) onDropped,
  }) {
    return DropTarget(
      onDragDone: (detail) async {
        if (_busy) return;
        if (detail.files.isEmpty) return;
        final xf = detail.files.first;
        if (!_isPdf(xf)) return;
        await onDropped(xf);
      },
      child: _outlinedAction(
        icon: Icons.download_rounded,
        label: '드롭',
        // 버튼 클릭 자체는 "드롭 안내"용(아무 동작 없음)
        onPressed: _busy ? null : () {},
      ),
    );
  }

  Widget _header(String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(color: _rsText, fontSize: 18, fontWeight: FontWeight.w900)),
        const SizedBox(height: 6),
        Text(subtitle, style: const TextStyle(color: _rsTextSub, fontSize: 13, fontWeight: FontWeight.w800)),
      ],
    );
  }

  Future<void> _savePending() async {
    if (_busy) return;
    final bi = _bookIndex;
    if (bi == null) return;
    if (_pendingByGradeIndex.isEmpty) return;
    if (_step != 1) return;

    final entries = _pendingByGradeIndex.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    setState(() => _busy = true);
    try {
      for (final e in entries) {
        final ok = await widget.onAttach(bookIndex: bi, gradeIndex: e.key, file: e.value);
        if (!ok) return; // 사용자가 교체를 취소한 경우 등: 다이얼로그 유지
      }
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final books = widget.books;
    final grades = widget.grades;
    final maxH = (MediaQuery.of(context).size.height * 0.78).clamp(380.0, 680.0).toDouble();

    final int? selectedBookIndex = _bookIndex;
    final _BookItem? selectedBook =
        (selectedBookIndex != null && selectedBookIndex >= 0 && selectedBookIndex < books.length)
            ? books[selectedBookIndex]
            : null;

    Widget bodyBookList() {
      return Scrollbar(
        controller: _scrollCtrl,
        thumbVisibility: true,
        child: ListView.separated(
          controller: _scrollCtrl,
          padding: const EdgeInsets.only(top: 8),
          itemCount: books.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final b = books[index];
            return InkWell(
              onTap: _busy
                  ? null
                  : () {
                      setState(() {
                        _bookIndex = index;
                        _step = 1;
                        _pendingByGradeIndex.clear();
                      });
                    },
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.all(10),
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
                            style: const TextStyle(
                              color: _rsTextSub,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              height: 1.25,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Icon(Icons.chevron_right, color: Colors.white24, size: 22),
                  ],
                ),
              ),
            );
          },
        ),
      );
    }

    Widget bodyGradeList() {
      final b = selectedBook;
      if (b == null) {
        return const SizedBox.shrink();
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _rsPanelBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _rsBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(b.name, style: const TextStyle(color: _rsText, fontSize: 14, fontWeight: FontWeight.w900)),
                const SizedBox(height: 6),
                Text(
                  '변경 예정: ${_pendingByGradeIndex.length}개',
                  style: const TextStyle(color: _rsTextSub, fontSize: 12, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                const Text(
                  '각 과정 행의 “드롭/찾기”로 PDF를 지정한 뒤, 우측 아래 “저장”으로 한 번에 반영하세요.',
                  style: TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.w700, height: 1.25),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Scrollbar(
              controller: _scrollCtrl,
              thumbVisibility: true,
              child: ListView.separated(
                controller: _scrollCtrl,
                itemCount: grades.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final g = grades[index];
                  final existing = widget.pdfPathByBookAndGrade[b.id]?[g.key];
                  final linked = existing != null && existing.trim().isNotEmpty;
                  final fileLabel = linked ? widget.basenameOf(existing!) : '미연결';
                  final pending = _pendingByGradeIndex[index];
                  final hasPending = pending != null && pending.path.trim().isNotEmpty;

                  return Container(
                    padding: const EdgeInsets.all(10),
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
                                g.label,
                                style: TextStyle(
                                  color: linked ? _rsText : _rsTextSub,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w900,
                                  height: 1.15,
                                ),
                                softWrap: true,
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Icon(
                                    Icons.picture_as_pdf_outlined,
                                    size: 16,
                                    color: (linked || hasPending) ? _rsTextSub : Colors.white24,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      fileLabel,
                                      style: TextStyle(
                                        color: linked ? _rsText : _rsTextSub,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                              if (hasPending) ...[
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    const Icon(Icons.arrow_right_alt, size: 16, color: _rsAccent),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        pending!.name,
                                        style: const TextStyle(
                                          color: _rsAccent,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w900,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Row(
                          children: [
                            SizedBox(
                              width: 92,
                              child: _dropButton(
                                onDropped: (xf) async {
                                  if (_busy) return;
                                  setState(() => _pendingByGradeIndex[index] = xf);
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 92,
                              child: _outlinedAction(
                                icon: Icons.folder_open,
                                label: '찾기',
                                onPressed: _busy
                                    ? null
                                    : () async {
                                        final xf = await _pickPdf();
                                        if (xf == null) return;
                                        if (!_isPdf(xf)) return;
                                        setState(() => _pendingByGradeIndex[index] = xf);
                                      },
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      );
    }

    final title = (_step == 0) ? 'PDF 연결' : 'PDF 연결';
    final subtitle = (_step == 0) ? '1/2 · 책을 선택하세요' : '2/2 · 과정별 PDF를 지정하고 저장하세요';
    final desiredH = (_step == 0) ? (220.0 + books.length * 78.0) : (260.0 + grades.length * 104.0);
    final bodyHeight = desiredH.clamp(360.0, maxH).toDouble();

    return AlertDialog(
      backgroundColor: _rsBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: _rsBorder),
      ),
      titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
      contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      title: _header(title, subtitle),
      content: SizedBox(
        width: 600,
        height: bodyHeight,
        child: (_step == 0) ? bodyBookList() : bodyGradeList(),
      ),
      actions: [
        if (_step == 1)
          TextButton(
            onPressed: _busy
                ? null
                : () {
                    setState(() {
                      _step = 0;
                      _pendingByGradeIndex.clear();
                    });
                  },
            style: TextButton.styleFrom(foregroundColor: _rsTextSub),
            child: const Text('뒤로'),
          ),
        if (_step == 1) ...[
          const SizedBox(width: 8),
          FilledButton(
            onPressed: (_busy || _pendingByGradeIndex.isEmpty) ? null : _savePending,
            style: FilledButton.styleFrom(
              backgroundColor: _rsAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: Text(
              _pendingByGradeIndex.isEmpty ? '저장' : '저장 (${_pendingByGradeIndex.length})',
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
        ],
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(foregroundColor: _rsTextSub),
          child: const Text('닫기'),
        ),
      ],
    );
  }
}


