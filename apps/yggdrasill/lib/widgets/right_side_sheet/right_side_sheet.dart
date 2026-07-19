import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';
import 'package:mneme_flutter/widgets/pdf/pdf_editor_dialog.dart';
import 'package:mneme_flutter/widgets/pdf/homework_answer_viewer_dialog.dart';
import 'package:open_filex/open_filex.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'package:uuid/uuid.dart';
import 'file_shortcut_tab.dart';
import '../../screens/design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';
import '../latex_text_renderer.dart';
import '../../app_overlays.dart';
import '../../models/memo.dart';
import '../../services/ai_summary.dart';
import '../../services/data_manager.dart';
import '../../services/learning_problem_bank_service.dart';
import '../../services/problem_question_issue_report_service.dart';
import '../../services/right_sheet_answer_preload_service.dart';
import '../../services/runtime_flags.dart';
import '../../services/tag_preset_service.dart';
import '../../services/tenant_service.dart';
import '../../services/textbook_pdf_service.dart';
import '../memo_dialogs.dart';
import '../../theme/ygg_semantic_colors.dart';

const Color _rsPanelBg = Color(0xFF10171A);
const Color _rsFieldBg = Color(0xFF15171C);
const Color _rsBorder = Color(0xFF223131);
const Color _rsText = Color(0xFFEAF2F2);
const Color _rsTextSub = Color(0xFF9FB3B3);
const Color _rsAccent = Color(0xFF33A373);

class _RightSheetFabColors {
  const _RightSheetFabColors({
    required this.surface,
    required this.panel,
    required this.field,
    required this.border,
    required this.text,
    required this.subText,
    required this.highlight,
    required this.shadows,
    required this.blurSigma,
  });

  final Color surface;
  final Color panel;
  final Color field;
  final Color border;
  final Color text;
  final Color subText;
  final Color highlight;
  final List<BoxShadow> shadows;
  final double blurSigma;
}

_RightSheetFabColors _rightSheetFabColors(BuildContext context) {
  final brightness = Theme.of(context).brightness;
  final panelStyle = PreviewAcademyPanelStyle.forBrightness(brightness);
  final borderColor =
      FabTabBarTokens.groupedCardBorderFor(brightness).top.color;

  return _RightSheetFabColors(
    surface: panelStyle.groupedCardBackground,
    panel: panelStyle.dropdownBackground,
    field: brightness == Brightness.light
        ? Colors.white
        : panelStyle.dropdownBackground,
    border: borderColor,
    text: panelStyle.title,
    subText: panelStyle.label,
    highlight: FabTabBarTokens.paletteFor(brightness).highlight,
    shadows: const [],
    blurSigma: 0,
  );
}

enum RightSideSheetMode {
  none,
  grading,
  answerKey,
  fileShortcut,
  pdfEdit,
  memo
}

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
  // 오른쪽 시트는 채점 전용으로 사용한다.
  RightSideSheetMode _mode = RightSideSheetMode.grading;
  final List<_BookItem> _books = <_BookItem>[];
  Map<String, Map<String, String>> _pdfPathByBookAndGrade =
      <String, Map<String, String>>{};
  int _bookSeq = 0;
  String? _selectedBookId;

  Future<void>? _answerKeyLoadFuture;
  String get _answerKeyCategory => 'textbook';
  bool get _answerKeyReadOnly => true;
  static const List<String> _answerKeyGradeOrder = [
    '초1',
    '초2',
    '초3',
    '초4',
    '초5',
    '초6',
    '중1',
    '중2',
    '중3',
    '고1',
    '고2',
    '고3',
    'N수',
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

  RightSideSheetTestGradingSession? _testGradingSession;

  // 메모 필터(전체 + 카테고리 3종)
  static const String _memoFilterAll = 'all';
  String _memoFilterKey = _memoFilterAll;

  // pdf 편집(범위 입력은 시트, 미리보기는 다이얼로그) 상태
  final TextEditingController _pdfEditInputCtrl =
      ImeAwareTextEditingController();
  final TextEditingController _pdfEditRangesCtrl =
      ImeAwareTextEditingController();
  final TextEditingController _pdfEditFileNameCtrl =
      ImeAwareTextEditingController();
  String? _pdfEditLastOutputPath;
  bool _pdfEditBusy = false;

  bool _looksLikeUuid(String s) {
    // uuid v4 뿐 아니라 일반 UUID 형식만 체크 (서버 컬럼이 uuid 타입)
    final re = RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
    return re.hasMatch(s);
  }

  @override
  void initState() {
    super.initState();
    _testGradingSession = rightSideSheetTestGradingSession.value;
    rightSideSheetTestGradingSession.addListener(_onTestGradingSessionChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncGradingTabActiveFlag();
    });
  }

  void _onTestGradingSessionChanged() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final next = rightSideSheetTestGradingSession.value;
      final hasSession = next != null;
      if (!hasSession) {
        rightSideSheetPdfPanelSession.value = null;
      }
      setState(() {
        _testGradingSession = next;
        if (hasSession) {
          _mode = RightSideSheetMode.grading;
        }
      });
      _syncGradingTabActiveFlag();
    });
  }

  /// 독립 채점 화면 활성 상태를 전역 notifier로 반영.
  /// (채점 화면에 있을 때만 우측 시트 너비를 확장하기 위해 사용)
  void _syncGradingTabActiveFlag() {
    final bool active =
        _mode == RightSideSheetMode.grading && _testGradingSession != null;
    if (rightSideSheetGradingTabActive.value != active) {
      rightSideSheetGradingTabActive.value = active;
    }
  }

  void _handleClose() {
    if (_mode == RightSideSheetMode.grading || _testGradingSession != null) {
      rightSideSheetPdfPanelSession.value = null;
      rightSideSheetTestGradingSession.value = null;
    }
    widget.onClose();
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
    rightSideSheetTestGradingSession.removeListener(
      _onTestGradingSessionChanged,
    );
    if (rightSideSheetGradingTabActive.value) {
      rightSideSheetGradingTabActive.value = false;
    }
    rightSideSheetPdfPanelSession.value = null;
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
    final unique =
        names.where((e) => e.trim().isNotEmpty).map((e) => e.trim()).toSet();
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
    return [...known, ...unknown]
        .map((n) => _GradeOption(key: n, label: n))
        .toList();
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
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('원본 PDF를 먼저 선택하세요.')));
      return;
    }
    if (!inPath.toLowerCase().endsWith('.pdf')) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('PDF 파일만 지원합니다.')));
      return;
    }
    if (ranges.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('페이지 범위를 입력하세요.')));
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
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('유효한 페이지 범위가 없습니다.')));
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
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('PDF 생성이 완료되었습니다.')));
    } finally {
      if (mounted) setState(() => _pdfEditBusy = false);
    }
  }

  Future<void> _openPdfPreviewSelectDialogFromSheet() async {
    final dlgCtx = widget.dialogContext ?? context;
    final inPath = _pdfEditInputCtrl.text.trim();
    if (inPath.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('원본 PDF를 먼저 선택하세요.')));
      return;
    }
    if (!inPath.toLowerCase().endsWith('.pdf')) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('PDF 파일만 지원합니다.')));
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
      final rows =
          await DataManager.instance.loadResourceFilesForCategory(category);
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

      if (!mounted) return;
      final derivedGrades = _grades.isNotEmpty
          ? _grades
          : _buildGradeOptionsFromNames(gradeNames);
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
        if (_selectedBookId != null &&
            !updatedBooks.any((b) => b.id == _selectedBookId)) {
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
          backgroundColor: context.yggSurfaceBase,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: _rsBorder),
          ),
          title: const Text(
            'PDF 교체',
            style: TextStyle(
                color: _rsText, fontSize: 18, fontWeight: FontWeight.w900),
          ),
          content: const Text(
            '이미 이 학년에 연결된 PDF가 있습니다.\n새 PDF로 교체할까요?',
            style: TextStyle(
                color: _rsTextSub,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                height: 1.4),
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
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text('교체',
                  style: TextStyle(fontWeight: FontWeight.w900)),
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
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('PDF 파일만 지원합니다.')));
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
        final m = _pdfPathByBookAndGrade.putIfAbsent(
            book.id, () => <String, String>{});
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
    final navCtx = widget.dialogContext ?? context;
    final titleBase = book.name.trim().isEmpty ? '답지 확인' : book.name.trim();

    Future<void> openInInternalViewer({
      required String filePath,
      required String gradeKey,
      required String gradeLabel,
    }) async {
      final normalizedPath = filePath.trim();
      if (normalizedPath.isEmpty) return;
      final normalizedGradeKey =
          gradeKey.trim().isEmpty ? 'unknown' : gradeKey.trim();
      final normalizedGradeLabel = gradeLabel.trim();
      final title = normalizedGradeLabel.isEmpty
          ? titleBase
          : '$titleBase · $normalizedGradeLabel';
      final solutionPath = await _resolveLinkedSolutionPath(
        bookId: book.id,
        gradeKey: normalizedGradeKey,
        gradeLabel: normalizedGradeLabel,
      );
      final cacheKey =
          'answerkey|$_answerKeyCategory|${book.id}|$normalizedGradeKey|$normalizedPath';
      try {
        widget.onClose();
        await openHomeworkAnswerViewerPage(
          navCtx,
          filePath: normalizedPath,
          title: title,
          solutionFilePath: solutionPath,
          cacheKey: cacheKey,
          enableConfirm: false,
        );
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('내부 PDF 뷰어를 열 수 없습니다.')),
        );
      }
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
      await openInInternalViewer(
        filePath: entry.value,
        gradeKey: entry.key,
        gradeLabel: entry.key,
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
    final effective =
        linkedIndices.contains(current) ? current : linkedIndices.first;
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
    await openInInternalViewer(
      filePath: path,
      gradeKey: grade.key,
      gradeLabel: grade.label,
    );
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
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('과정 목록이 저장되었습니다.')));
    } catch (e) {
      if (!mounted) return;
      final s = e.toString();
      final missingTable = s.contains('answer_key_grades') &&
          (s.contains('PGRST205') || s.toLowerCase().contains('schema cache'));
      if (missingTable) {
        final localLikelySaved = !RuntimeFlags.serverOnly &&
            (!TagPresetService.preferSupabaseRead ||
                TagPresetService.dualWrite);
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
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('과정 목록 저장에 실패했습니다.')));
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

  bool _isWebUrl(String raw) {
    final lower = raw.trim().toLowerCase();
    return lower.startsWith('http://') || lower.startsWith('https://');
  }

  String _toLocalFilePath(String rawPath) {
    final trimmed = rawPath.trim();
    if (trimmed.isEmpty || _isWebUrl(trimmed)) return '';
    if (trimmed.toLowerCase().startsWith('file://')) {
      try {
        return Uri.parse(trimmed).toFilePath(
          windows: !kIsWeb && Platform.isWindows,
        );
      } catch (_) {
        return '';
      }
    }
    return trimmed;
  }

  Future<String?> _resolveLinkedSolutionPath({
    required String bookId,
    required String gradeKey,
    required String gradeLabel,
  }) async {
    final normalizedBookId = bookId.trim();
    if (normalizedBookId.isEmpty) return null;
    try {
      final links =
          await DataManager.instance.loadResourceFileLinks(normalizedBookId);
      final normalizedGradeLabel = gradeLabel.trim();
      final normalizedGradeKey = gradeKey.trim();
      final raw = (links['$normalizedGradeLabel#sol'] ??
              links['$normalizedGradeKey#sol'] ??
              '')
          .trim();
      if (raw.isEmpty) return null;
      if (_isWebUrl(raw)) return raw;
      final localPath = _toLocalFilePath(raw);
      if (localPath.isEmpty || !localPath.toLowerCase().endsWith('.pdf')) {
        return null;
      }
      if (await File(localPath).exists()) return localPath;
    } catch (_) {}
    return null;
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
      final m =
          _pdfPathByBookAndGrade.putIfAbsent(book.id, () => <String, String>{});
      m[grade.key] = file.path;
    });
  }

  Future<void> _deletePdfLinkForBook({
    required _BookItem book,
    required _GradeOption grade,
  }) async {
    await DataManager.instance
        .deleteAnswerKeyBookPdf(bookId: book.id, gradeKey: grade.key);
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
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('과정이 없어 PDF 연결을 수정할 수 없습니다.')));
      return;
    }
    final dlgCtx = widget.dialogContext ?? context;
    final initial = Map<String, String>.from(
        _pdfPathByBookAndGrade[book.id] ?? const <String, String>{});
    await showDialog<void>(
      context: dlgCtx,
      useRootNavigator: true,
      builder: (_) => _BookPdfEditDialog(
        book: book,
        grades: _grades,
        initialPaths: initial,
        basenameOf: _basename,
        onPickAndSave: (grade, file) =>
            _savePdfLinkForBook(book: book, grade: grade, file: file),
        onDetach: (grade) => _deletePdfLinkForBook(book: book, grade: grade),
      ),
    );
  }

  Future<void> _onEditPdfsPressed() async {
    if (_books.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('수정할 책이 없습니다.')));
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
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('수정할 책이 없습니다.')));
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
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('책 정보 저장에 실패했습니다.')));
    }
  }

  Future<void> _onDeleteBookPressed() async {
    if (_books.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('삭제할 책이 없습니다.')));
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
          backgroundColor: context.yggSurfaceBase,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: _rsBorder),
          ),
          title: const Text(
            '책 삭제',
            style: TextStyle(
                color: _rsText, fontSize: 18, fontWeight: FontWeight.w900),
          ),
          content: Text(
            '“${book.name}”을(를) 삭제할까요?\n연결된 PDF도 함께 삭제됩니다.',
            style: const TextStyle(
                color: _rsTextSub,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                height: 1.4),
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
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text('삭제',
                  style: TextStyle(fontWeight: FontWeight.w900)),
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
      try {
        await _saveAllBooks();
      } catch (_) {}
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
            (s.contains('PGRST205') ||
                s.toLowerCase().contains('schema cache'));
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

  @override
  Widget build(BuildContext context) {
    final fabStyle = _rightSheetFabColors(context);
    final panelStyle = PreviewAcademyPanelStyle.forBrightness(
      Theme.of(context).brightness,
    );
    final sheetBorder = FabTabBarTokens.groupedCardBorderFor(
      Theme.of(context).brightness,
    );
    return Material(
      color: Colors.transparent,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: fabStyle.surface,
          border: Border(left: sheetBorder.left),
        ),
        child: SafeArea(
          child: Column(
            children: [
              if (_mode != RightSideSheetMode.grading)
                _TopIconBar(
                  mode: _mode,
                  onModeSelected: (m) {
                    setState(() => _mode = m);
                    _syncGradingTabActiveFlag();
                    if (m == RightSideSheetMode.answerKey) {
                      unawaited(_ensureGradesThenLoadAnswerKeyData());
                    }
                    if (m == RightSideSheetMode.memo) {
                      unawaited(DataManager.instance.loadMemos());
                    }
                  },
                  onClose: _handleClose,
                ),
              if (_mode != RightSideSheetMode.grading)
                Divider(height: 1, color: panelStyle.divider),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    switch (_mode) {
      case RightSideSheetMode.grading:
        return _AnswerKeyGradingTabPanel(
          session: _testGradingSession,
          dialogContext: widget.dialogContext,
          onClose: _handleClose,
          onClearSession: () {
            rightSideSheetTestGradingSession.value = null;
          },
        );
      case RightSideSheetMode.answerKey:
        // grades는 답지 기능의 핵심 의존성이라, 최초 진입 시 지연 로드 보장
        if (!_gradesLoaded && !_gradesLoading) {
          unawaited(_loadGrades());
        }
        return _AnswerKeyPdfShortcutExplorer(
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
        );
      case RightSideSheetMode.fileShortcut:
        return FileShortcutTab(dialogContext: widget.dialogContext);
      case RightSideSheetMode.pdfEdit:
        final inputPath = _pdfEditInputCtrl.text.trim();
        final hasPdf =
            inputPath.isNotEmpty && inputPath.toLowerCase().endsWith('.pdf');
        final hasRanges = _pdfEditRangesCtrl.text.trim().isNotEmpty;
        return Padding(
          padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'PDF 편집',
                style: TextStyle(
                    color: _rsText, fontSize: 16, fontWeight: FontWeight.w900),
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
                  style: TextStyle(
                      color: _rsTextSub,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      height: 1.35),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('입력 PDF',
                          style: TextStyle(
                              color: _rsTextSub, fontWeight: FontWeight.w800)),
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
                        style: const TextStyle(
                            color: _rsText, fontWeight: FontWeight.w700),
                        decoration: InputDecoration(
                          hintText: '원본 PDF 경로',
                          hintStyle: const TextStyle(color: _rsTextSub),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: _rsBorder),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide:
                                const BorderSide(color: _rsAccent, width: 1.4),
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
                          if (path != null &&
                              path.toLowerCase().endsWith('.pdf')) {
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
                            style: TextStyle(
                                color: _rsTextSub, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed:
                                  _pdfEditBusy ? null : _pickPdfEditInput,
                              icon: const Icon(Icons.folder_open, size: 16),
                              label: const Text('찾기'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: _rsTextSub,
                                side: const BorderSide(color: _rsBorder),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10)),
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (hasPdf) ...[
                        const SizedBox(height: 14),
                        const Text(
                          '페이지 범위 (예: 1-3,5,7-9)',
                          style: TextStyle(
                              color: _rsTextSub, fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 6),
                        TextField(
                          controller: _pdfEditRangesCtrl,
                          onChanged: (_) {
                            if (_pdfEditBusy) return;
                            setState(() {});
                          },
                          style: const TextStyle(
                              color: _rsText, fontWeight: FontWeight.w700),
                          decoration: InputDecoration(
                            hintText: '쉼표로 구분, 범위는 하이픈',
                            hintStyle: const TextStyle(color: _rsTextSub),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(color: _rsBorder),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(
                                  color: _rsAccent, width: 1.4),
                            ),
                            filled: true,
                            fillColor: _rsFieldBg,
                          ),
                        ),
                      ],
                      if (hasPdf && hasRanges) ...[
                        const SizedBox(height: 14),
                        const Text('파일명',
                            style: TextStyle(
                                color: _rsTextSub,
                                fontWeight: FontWeight.w800)),
                        const SizedBox(height: 6),
                        TextField(
                          controller: _pdfEditFileNameCtrl,
                          style: const TextStyle(
                              color: _rsText, fontWeight: FontWeight.w700),
                          decoration: InputDecoration(
                            hintText: '원본명_과정_본문.pdf',
                            hintStyle: const TextStyle(color: _rsTextSub),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(color: _rsBorder),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(
                                  color: _rsAccent, width: 1.4),
                            ),
                            filled: true,
                            fillColor: _rsFieldBg,
                          ),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          height: 48,
                          child: FilledButton.icon(
                            onPressed: _pdfEditBusy
                                ? null
                                : _generatePdfFromRangesInSheet,
                            icon: _pdfEditBusy
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2))
                                : const Icon(Icons.save_outlined, size: 16),
                            label: const Text('범위로 생성'),
                            style: FilledButton.styleFrom(
                              backgroundColor: _rsAccent,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      if (_pdfEditLastOutputPath != null &&
                          _pdfEditLastOutputPath!.trim().isNotEmpty)
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: _rsFieldBg,
                            borderRadius: BorderRadius.circular(12),
                            border:
                                Border.all(color: _rsBorder.withOpacity(0.9)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('마지막 생성',
                                  style: TextStyle(
                                      color: _rsTextSub,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w900)),
                              const SizedBox(height: 6),
                              Text(
                                _basename(_pdfEditLastOutputPath!),
                                style: const TextStyle(
                                    color: _rsText,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w800),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  OutlinedButton(
                                    onPressed: () async {
                                      try {
                                        await OpenFilex.open(
                                            _pdfEditLastOutputPath!);
                                      } catch (_) {}
                                    },
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.white70,
                                      side: BorderSide(
                                          color: _rsBorder.withOpacity(0.9)),
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(10)),
                                    ),
                                    child: const Text('열기'),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '과정: ${_currentGradeLabelForPdfEdit()}',
                                    style: const TextStyle(
                                        color: _rsTextSub,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w800),
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
                transitionBuilder: (child, anim) =>
                    FadeTransition(opacity: anim, child: child),
                child: hasPdf
                    ? SizedBox(
                        key: const ValueKey('pdf_edit_preview_btn'),
                        height: 48,
                        child: OutlinedButton.icon(
                          onPressed: _pdfEditBusy
                              ? null
                              : _openPdfPreviewSelectDialogFromSheet,
                          icon: const Icon(Icons.preview_outlined, size: 16),
                          label: const Text('미리보기로 편집'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _rsTextSub,
                            side: const BorderSide(color: _rsBorder),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
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
    final initialCat = (_memoFilterKey == MemoCategory.schedule ||
            _memoFilterKey == MemoCategory.consult ||
            _memoFilterKey == MemoCategory.inquiry)
        ? _memoFilterKey
        : MemoCategory.schedule;
    final result = await showDialog<MemoCreateResult>(
      context: dlgCtx,
      useRootNavigator: true,
      builder: (_) => MemoInputDialog(initialCategoryKey: initialCat),
    );
    if (result == null) return;
    await addMemoFromCreateResult(result);
  }

  Future<void> _onEditMemoPressed(Memo item) async {
    final dlgCtx = widget.dialogContext ?? context;
    if (item.categoryKey == MemoCategory.inquiry) {
      final edited = await showDialog<MemoInquiryEditResult>(
        context: dlgCtx,
        useRootNavigator: true,
        builder: (_) => MemoInquiryEditDialog(
          initialPhone: item.inquiryPhone ?? '',
          initialSchoolGrade: item.inquirySchoolGrade ?? '',
          initialAvailability: item.inquiryAvailability ?? '',
          initialNote: item.inquiryNote ?? '',
          fallbackOriginal: item.original,
        ),
      );
      if (edited == null) return;
      await applyMemoInquiryEdit(item: item, edited: edited);
      return;
    }
    final edited = await showDialog<MemoEditResult>(
      context: dlgCtx,
      useRootNavigator: true,
      builder: (_) => MemoEditDialog(
          initial: item.original, initialScheduledAt: item.scheduledAt),
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
}

class RightSideSheetMemoPanel extends StatefulWidget {
  const RightSideSheetMemoPanel({
    super.key,
    this.dialogContext,
  });

  final BuildContext? dialogContext;

  @override
  State<RightSideSheetMemoPanel> createState() =>
      _RightSideSheetMemoPanelState();
}

class _RightSideSheetMemoPanelState extends State<RightSideSheetMemoPanel> {
  String _memoFilterKey = _RightSideSheetState._memoFilterAll;

  @override
  void initState() {
    super.initState();
    unawaited(DataManager.instance.loadMemos());
  }

  Future<void> _onAddMemoPressed() async {
    final dlgCtx = widget.dialogContext ?? context;
    final initialCat = (_memoFilterKey == MemoCategory.schedule ||
            _memoFilterKey == MemoCategory.consult ||
            _memoFilterKey == MemoCategory.inquiry)
        ? _memoFilterKey
        : MemoCategory.schedule;
    final result = await showDialog<MemoCreateResult>(
      context: dlgCtx,
      useRootNavigator: true,
      builder: (_) => MemoInputDialog(initialCategoryKey: initialCat),
    );
    if (result == null) return;
    await addMemoFromCreateResult(result);
  }

  Future<void> _onEditMemoPressed(Memo item) async {
    final dlgCtx = widget.dialogContext ?? context;
    if (item.categoryKey == MemoCategory.inquiry) {
      final edited = await showDialog<MemoInquiryEditResult>(
        context: dlgCtx,
        useRootNavigator: true,
        builder: (_) => MemoInquiryEditDialog(
          initialPhone: item.inquiryPhone ?? '',
          initialSchoolGrade: item.inquirySchoolGrade ?? '',
          initialAvailability: item.inquiryAvailability ?? '',
          initialNote: item.inquiryNote ?? '',
          fallbackOriginal: item.original,
        ),
      );
      if (edited == null) return;
      await applyMemoInquiryEdit(item: item, edited: edited);
      return;
    }

    final edited = await showDialog<MemoEditResult>(
      context: dlgCtx,
      useRootNavigator: true,
      builder: (_) => MemoEditDialog(
        initial: item.original,
        initialScheduledAt: item.scheduledAt,
      ),
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

  @override
  Widget build(BuildContext context) {
    return _MemoExplorer(
      memosListenable: DataManager.instance.memosNotifier,
      onAddMemo: () => unawaited(_onAddMemoPressed()),
      onEditMemo: (memo) => unawaited(_onEditMemoPressed(memo)),
      selectedFilterKey: _memoFilterKey,
      onFilterChanged: (key) => setState(() => _memoFilterKey = key),
    );
  }
}

class _TopIconBar extends StatelessWidget {
  final RightSideSheetMode mode;
  final ValueChanged<RightSideSheetMode> onModeSelected;
  final VoidCallback onClose;

  const _TopIconBar(
      {required this.mode,
      required this.onModeSelected,
      required this.onClose});

  Color _colorFor(RightSideSheetMode m) =>
      (mode == m) ? _rsAccent : Colors.white70;

  @override
  Widget build(BuildContext context) {
    final fabStyle = _rightSheetFabColors(context);
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          const SizedBox(width: 4),
          IconButton(
            tooltip: '닫기',
            onPressed: onClose,
            icon: const Icon(Icons.chevron_right),
            color: fabStyle.subText,
          ),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: const [],
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
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.add, size: 18),
            label:
                const Text('추가', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ),
      ),
    );
  }
}

// -------------------- 메모 --------------------

class _InquiryMemoCard extends StatefulWidget {
  final Memo memo;

  /// 목록 위에서부터 1-based 순번
  final int ordinalFromTop;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _InquiryMemoCard({
    super.key,
    required this.memo,
    required this.ordinalFromTop,
    required this.onTap,
    required this.onDelete,
  });

  @override
  State<_InquiryMemoCard> createState() => _InquiryMemoCardState();
}

class _InquiryMemoCardState extends State<_InquiryMemoCard>
    with SingleTickerProviderStateMixin {
  static const double _actionPaneWidth = 74;
  static const double _minCardHeight = 96;
  static const Duration _snapDuration = Duration(milliseconds: 160);

  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: _snapDuration);

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

  static String _disp(String? s) {
    final t = (s ?? '').trim();
    return t.isEmpty ? '—' : t;
  }

  Widget _fieldRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            label,
            textAlign: TextAlign.left,
            style: const TextStyle(
                color: _rsTextSub, fontSize: 12, fontWeight: FontWeight.w900),
          ),
        ),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                color: _rsText,
                fontSize: 14,
                fontWeight: FontWeight.w800,
                height: 1.3),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(14);
    final m = widget.memo;
    final dateLabel = '${m.createdAt.month}/${m.createdAt.day}';
    final lines = memoInquiryCardLines(m);

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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          '${widget.ordinalFromTop}',
                          textAlign: TextAlign.left,
                          style: const TextStyle(
                            color: _rsText,
                            fontSize: 15,
                            fontWeight: FontWeight.w900,
                            height: 1.0,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          dateLabel,
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                              color: _rsTextSub,
                              fontSize: 12,
                              fontWeight: FontWeight.w900),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 9),
                  _fieldRow('연락처', _disp(lines.contact)),
                  const SizedBox(height: 4),
                  _fieldRow('학교·학년', _disp(lines.schoolGrade)),
                  const SizedBox(height: 4),
                  _fieldRow('가능 요일·시간', _disp(lines.availability)),
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
                            child: Icon(Icons.delete_outline_rounded,
                                size: 18, color: Colors.white),
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
                    return Transform.translate(
                        offset: Offset(dx, 0), child: child);
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

class _InquiryMemosReorderList extends StatefulWidget {
  final ValueListenable<List<Memo>> memosListenable;
  final void Function(Memo) onEditMemo;

  const _InquiryMemosReorderList({
    super.key,
    required this.memosListenable,
    required this.onEditMemo,
  });

  @override
  State<_InquiryMemosReorderList> createState() =>
      _InquiryMemosReorderListState();
}

class _InquiryMemosReorderListState extends State<_InquiryMemosReorderList> {
  final ScrollController _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    // 문의 탭으로 전환될 때마다 위젯이 새로 붙으므로 서버/로컬 목록 갱신
    unawaited(DataManager.instance.loadMemos());
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  List<Memo> _sorted(List<Memo> all) {
    final list = all.where(memoIsFormInquiryForList).toList();
    list.sort(compareInquiryMemos);
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Memo>>(
      valueListenable: widget.memosListenable,
      builder: (context, memos, _) {
        final list = _sorted(memos);
        final countLabel = Text(
          '총 ${list.length}개',
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: _rsTextSub,
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        );
        if (list.isEmpty) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: countLabel,
              ),
              const Expanded(
                child: Center(
                  child: Text(
                    '문의 메모 없음',
                    style: TextStyle(
                        color: _rsTextSub,
                        fontSize: 13,
                        fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: countLabel,
            ),
            Expanded(
              child: Scrollbar(
                controller: _scrollCtrl,
                thumbVisibility: true,
                child: ReorderableListView.builder(
                  scrollController: _scrollCtrl,
                  buildDefaultDragHandles: false,
                  itemCount: list.length,
                  onReorder: (oldIndex, newIndex) {
                    if (newIndex > oldIndex) newIndex -= 1;
                    final next = List<Memo>.from(list);
                    final item = next.removeAt(oldIndex);
                    next.insert(newIndex, item);
                    unawaited(DataManager.instance
                        .reorderInquiryMemos(next.map((m) => m.id).toList()));
                  },
                  proxyDecorator: (child, index, animation) {
                    final curved = CurvedAnimation(
                        parent: animation, curve: Curves.easeOutCubic);
                    return AnimatedBuilder(
                      animation: curved,
                      builder: (context, _) {
                        final v = curved.value;
                        return Transform.translate(
                          offset: Offset(0, -4 * v),
                          child: Transform.scale(
                            scale: 1.0 + 0.02 * v,
                            child: Material(
                              color: context.yggSurfaceBase,
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
                    final m = list[index];
                    return ReorderableDelayedDragStartListener(
                      key: ValueKey('inq:${m.id}'),
                      index: index,
                      child: Padding(
                        padding: EdgeInsets.only(
                            bottom: index == list.length - 1 ? 0 : 8),
                        child: _InquiryMemoCard(
                          memo: m,
                          ordinalFromTop: index + 1,
                          onTap: () => widget.onEditMemo(m),
                          onDelete: () =>
                              unawaited(DataManager.instance.deleteMemo(m.id)),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _MemoExplorer extends StatelessWidget {
  final ValueListenable<List<Memo>> memosListenable;
  final VoidCallback onAddMemo;
  final void Function(Memo memo) onEditMemo;
  final String selectedFilterKey; // 'all' | MemoCategory.*
  final ValueChanged<String> onFilterChanged;

  const _MemoExplorer({
    required this.memosListenable,
    required this.onAddMemo,
    required this.onEditMemo,
    required this.selectedFilterKey,
    required this.onFilterChanged,
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
            style: TextStyle(
                color: _rsText, fontSize: 16, fontWeight: FontWeight.w900),
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
                  constraints:
                      const BoxConstraints(minWidth: 44, minHeight: 44),
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
                var list = [...memos]
                  ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
                if (selectedFilterKey != _RightSideSheetState._memoFilterAll) {
                  list = list
                      .where((m) => m.categoryKey == selectedFilterKey)
                      .toList();
                }

                if (selectedFilterKey == MemoCategory.inquiry) {
                  return _InquiryMemosReorderList(
                    memosListenable: memosListenable,
                    onEditMemo: onEditMemo,
                  );
                }

                if (list.isEmpty) {
                  return const Center(
                    child: Text('메모 없음',
                        style: TextStyle(
                            color: _rsTextSub,
                            fontSize: 13,
                            fontWeight: FontWeight.w700)),
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
                      onDelete: () =>
                          unawaited(DataManager.instance.deleteMemo(m.id)),
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

class _MemoCardState extends State<_MemoCard>
    with SingleTickerProviderStateMixin {
  // 삭제 액션 패널 너비를 30% 축소 (108 -> 75.6)
  // 단일 삭제 액션은 2버튼(140) 기준 "1버튼 분량"만 차지하도록 축소
  static const double _actionPaneWidth = 74;
  static const double _minCardHeight = 96;
  static const Duration _snapDuration = Duration(milliseconds: 160);

  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: _snapDuration);

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
                              style: const TextStyle(
                                  color: _rsTextSub,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w900),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: _rsPanelBg,
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(color: _rsBorder),
                              ),
                              child: Text(
                                widget.categoryLabel,
                                style: const TextStyle(
                                    color: _rsTextSub,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w900),
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
                                  style: const TextStyle(
                                      color: _rsTextSub,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700),
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
                    style: const TextStyle(
                        color: _rsText,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        height: 1.3),
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
                            child: Icon(Icons.delete_outline_rounded,
                                size: 18, color: Colors.white),
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
                    return Transform.translate(
                        offset: Offset(dx, 0), child: child);
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

  const _MemoFilterPill(
      {required this.label, required this.selected, required this.onTap});

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

class _RightSheetGradingCellVm {
  final String key;
  final int questionIndex;
  final String questionLabel;
  final String answer;
  final String answerMode;
  final String answerImageUrl;
  final int? answerImageWidth;
  final int? answerImageHeight;
  final double? answerImagePixelRatio;
  final String answerRenderPolicy;
  final String answerSourceKind;
  final String answerSourceId;
  final String answerAssetKind;
  final String answerRenderStyleVersion;
  final int? answerPageNumber;
  final List<int> answerRect1k;
  final List<int> focusRect1k;
  final String answerPathRaw;
  final String solutionPathRaw;
  final int? solutionPageNumber;
  final List<int> solutionRect1k;
  final Map<String, String> sourceInfo;

  const _RightSheetGradingCellVm({
    required this.key,
    required this.questionIndex,
    this.questionLabel = '',
    required this.answer,
    this.answerMode = '',
    this.answerImageUrl = '',
    this.answerImageWidth,
    this.answerImageHeight,
    this.answerImagePixelRatio,
    this.answerRenderPolicy = '',
    this.answerSourceKind = '',
    this.answerSourceId = '',
    this.answerAssetKind = '',
    this.answerRenderStyleVersion = '',
    this.answerPageNumber,
    this.answerRect1k = const <int>[],
    this.focusRect1k = const <int>[],
    this.answerPathRaw = '',
    this.solutionPathRaw = '',
    this.solutionPageNumber,
    this.solutionRect1k = const <int>[],
    this.sourceInfo = const <String, String>{},
  });

  String get displayQuestionLabel {
    final label = questionLabel.trim();
    return label.isEmpty ? '$questionIndex' : label;
  }
}

class _RightSheetGradingPageVm {
  final int pageNumber;
  final List<_RightSheetGradingCellVm> cells;

  const _RightSheetGradingPageVm({
    required this.pageNumber,
    required this.cells,
  });
}

class _RightSheetAnswerListRow extends StatefulWidget {
  final String questionLabel;
  final bool editLocked;
  final String state;
  final String baselineState;
  final bool correctedRetry;
  final int correctionAttemptNumber;
  final Color backgroundColor;
  final Color borderColor;
  final double answerSlotHeight;
  final bool hasSourceInfo;
  final Future<void> Function() onOpenSolution;
  final VoidCallback onReportIssue;
  final VoidCallback onToggleState;
  final VoidCallback onShowSourceInfo;
  final Widget answerChild;
  final bool solutionOpening;
  final bool solutionOpenBlocked;

  const _RightSheetAnswerListRow({
    required this.questionLabel,
    required this.editLocked,
    required this.state,
    this.baselineState = '',
    this.correctedRetry = false,
    this.correctionAttemptNumber = 0,
    required this.backgroundColor,
    required this.borderColor,
    required this.answerSlotHeight,
    required this.hasSourceInfo,
    required this.onOpenSolution,
    required this.onReportIssue,
    required this.onToggleState,
    required this.onShowSourceInfo,
    required this.answerChild,
    this.solutionOpening = false,
    this.solutionOpenBlocked = false,
  });

  @override
  State<_RightSheetAnswerListRow> createState() =>
      _RightSheetAnswerListRowState();
}

class _RightSheetAnswerListRowState extends State<_RightSheetAnswerListRow>
    with SingleTickerProviderStateMixin {
  static const double _actionPaneWidth = 62;
  static const Duration _snapDuration = Duration(milliseconds: 170);
  static const double _cardRadius = 12.0;
  static const double _cardBorderWidth = 2.2;

  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: _snapDuration);

  bool get _isOpen => _ctrl.value > 0.01;

  void _open() => _ctrl.animateTo(1, curve: Curves.easeOutCubic);
  void _close() => _ctrl.animateTo(0, curve: Curves.easeOutCubic);

  void _handleHorizontalDragUpdate(DragUpdateDetails details) {
    final next = _ctrl.value + (details.delta.dx / _actionPaneWidth);
    _ctrl.value = next.clamp(0.0, 1.0);
  }

  void _handleHorizontalDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0.0;
    if (velocity > 250) {
      _open();
      return;
    }
    if (velocity < -250) {
      _close();
      return;
    }
    if (_ctrl.value >= 0.45) {
      _open();
    } else {
      _close();
    }
  }

  void _runFrontAction(VoidCallback action) {
    if (_isOpen) {
      _close();
      return;
    }
    action();
  }

  void _showInfo() {
    _close();
    widget.onShowSourceInfo();
  }

  Future<void> _openSolution() async {
    if (widget.solutionOpenBlocked) return;
    _close();
    await widget.onOpenSolution();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(_cardRadius);
    final questionLabel = widget.questionLabel;
    final infoColor = widget.hasSourceInfo ? _rsAccent : _rsTextSub;
    final correctionBadgeLabel = widget.correctionAttemptNumber > 0
        ? '수정 ${widget.correctionAttemptNumber}'
        : '수정';

    Widget questionButton() {
      final busy = widget.solutionOpening;
      return Tooltip(
        message:
            busy ? '$questionLabel번 해설 PDF 여는 중' : '$questionLabel번 해설 PDF로 이동',
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: widget.solutionOpenBlocked
              ? null
              : () => unawaited(_openSolution()),
          onLongPress: widget.solutionOpenBlocked ? null : widget.onReportIssue,
          child: SizedBox(
            width: 56,
            height: 44,
            child: Center(
              child: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: _rsAccent,
                      ),
                    )
                  : Text(
                      questionLabel,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        height: 1.0,
                        letterSpacing: -0.2,
                      ),
                    ),
            ),
          ),
        ),
      );
    }

    Widget answerCard() {
      final shape = RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(
          color: widget.borderColor,
          width: _cardBorderWidth,
        ),
      );
      return Material(
        color: widget.backgroundColor,
        surfaceTintColor: Colors.transparent,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: shape,
          onTap: () => _runFrontAction(widget.onToggleState),
          splashFactory: NoSplash.splashFactory,
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          hoverColor: Colors.transparent,
          focusColor: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 13.7,
              vertical: 13.7,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: SizedBox(
                    height: widget.answerSlotHeight,
                    child: Opacity(
                      opacity: widget.state == 'unsolved' ? 0.42 : 1.0,
                      child: widget.answerChild,
                    ),
                  ),
                ),
                if (widget.correctedRetry) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(
                      color: _rsAccent.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: _rsAccent.withValues(alpha: 0.55),
                      ),
                    ),
                    child: Text(
                      correctionBadgeLabel,
                      style: const TextStyle(
                        color: _rsAccent,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w900,
                        height: 1.0,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return Material(
      color: Colors.transparent,
      child: Tooltip(
        message: widget.correctedRetry
            ? '$questionLabel번 · 첫 시도 ${widget.baselineState == 'unsolved' ? '미풀이' : '오답'} → 수정됨'
            : widget.editLocked
                ? '$questionLabel번 · 저장된 채점 결과'
                : '$questionLabel번',
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            questionButton(),
            const SizedBox(width: 8),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragUpdate: _handleHorizontalDragUpdate,
                onHorizontalDragEnd: _handleHorizontalDragEnd,
                onHorizontalDragCancel: _close,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(_cardRadius),
                  child: Stack(
                    children: [
                      Positioned(
                        left: 0,
                        top: 0,
                        bottom: 0,
                        width: _actionPaneWidth,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Material(
                            color: infoColor.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(11),
                            child: InkWell(
                              onTap: _showInfo,
                              borderRadius: BorderRadius.circular(11),
                              splashFactory: NoSplash.splashFactory,
                              child: SizedBox.expand(
                                child: Icon(
                                  Icons.info_outline_rounded,
                                  size: 21,
                                  color: infoColor,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      AnimatedBuilder(
                        animation: _ctrl,
                        builder: (context, child) {
                          final dx = _actionPaneWidth * _ctrl.value;
                          return Transform.translate(
                            offset: Offset(dx, 0),
                            child: child,
                          );
                        },
                        child: answerCard(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AnswerKeyGradingTabPanel extends StatefulWidget {
  final RightSideSheetTestGradingSession? session;
  final BuildContext? dialogContext;
  final VoidCallback onClose;
  final VoidCallback onClearSession;

  const _AnswerKeyGradingTabPanel({
    required this.session,
    this.dialogContext,
    required this.onClose,
    required this.onClearSession,
  });

  @override
  State<_AnswerKeyGradingTabPanel> createState() =>
      _AnswerKeyGradingTabPanelState();
}

class _AnswerKeyGradingTabPanelState extends State<_AnswerKeyGradingTabPanel> {
  static const double _topBarTopInset = 12;
  static const double _searchFieldHeight = 48;
  static const String _historyPrefKey =
      'right_sheet_grading_recent_searches_v1';
  static const int _historyLimit = 10;
  static const int _suggestDebounceMs = 200;
  static const double _answerSlotHeight = 46.0;
  static const double _answerImageTopPadding = 8.0;
  static const double _answerImageBottomPadding = 10.0;
  static const double _answerImageVerticalPadding =
      _answerImageTopPadding + _answerImageBottomPadding;
  static const double _answerRenderDefaultPixelRatio = 7.0;
  static const double _inlineAnswerLineHeight = 30.0;

  final TextEditingController _searchCtrl = ImeAwareTextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final GlobalKey _searchHeaderFieldKey = GlobalKey();
  final GlobalKey _gradingSearchOverlayKey = GlobalKey();
  double _gradingSearchOverlayHeight =
      _topBarTopInset + _searchFieldHeight + 24;
  Timer? _searchSuggestDebounce;
  Timer? _searchBlurHideTimer;
  OverlayEntry? _searchSuggestionOverlayEntry;
  int _searchSuggestRequestSeq = 0;
  bool _searchDropdownTapInProgress = false;
  List<String> _recentSearches = <String>[];
  List<RightSheetGradingSearchResult> _searchSuggestions =
      const <RightSheetGradingSearchResult>[];
  List<RightSheetGradingSearchResult> _searchResults =
      const <RightSheetGradingSearchResult>[];
  bool _searchSuggestBusy = false;
  bool _searchBusy = false;
  bool _searchOpenBusy = false;
  String? _searchSuggestError;
  String? _searchError;
  Map<String, String> _gradingStates = <String, String>{};
  Map<String, String> _baselineStates = <String, String>{};
  Map<String, String> _correctionStates = <String, String>{};
  Map<String, int> _correctionAttemptNumbers = <String, int>{};
  String _boundSessionId = '';
  RightSideSheetTestGradingSession? _boundSessionRef;
  bool _gradingEditLocked = false;
  bool _wrongOnly = false;
  bool _editResetBusy = false;
  bool _actionBusy = false;
  bool _answerPdfOpening = false;
  String _openingSolutionCellKey = '';
  int _pdfFocusRequestSeq = 0;
  String _autoOpenedAnswerSessionId = '';
  Map<String, LearningProblemAnswerRender> _answerRenders =
      <String, LearningProblemAnswerRender>{};
  Set<String> _answerRenderFailedKeys = <String>{};
  int _answerRenderRequestSeq = 0;
  String _lastAnswerRenderRouteLogKey = '';

  @override
  void initState() {
    super.initState();
    _searchFocus.addListener(_handleSearchFocusChanged);
    _hydrateSessionState(force: true);
    unawaited(_loadRecentSearches().then((_) => _hydrateRecentSearchLabels()));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncGradingSearchOverlayHeight();
    });
  }

  @override
  void didUpdateWidget(covariant _AnswerKeyGradingTabPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _hydrateSessionState();
  }

  @override
  void dispose() {
    _searchSuggestDebounce?.cancel();
    _searchBlurHideTimer?.cancel();
    _removeSuggestionOverlay();
    _searchFocus.removeListener(_handleSearchFocusChanged);
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _handleSearchFocusChanged() {
    _searchBlurHideTimer?.cancel();
    if (_searchFocus.hasFocus) {
      if (!mounted) return;
      setState(() {});
      _scheduleSuggestionOverlaySync();
      return;
    }
    _searchBlurHideTimer = Timer(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      if (_searchDropdownTapInProgress) return;
      setState(() {});
      _scheduleSuggestionOverlaySync();
    });
  }

  void _setSearchDropdownTapInProgress(bool value) {
    if (_searchDropdownTapInProgress == value) return;
    if (!mounted) return;
    setState(() {
      _searchDropdownTapInProgress = value;
    });
    _scheduleSuggestionOverlaySync();
  }

  void _scheduleSuggestionOverlaySync() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncSuggestionOverlay();
    });
  }

  void _syncSuggestionOverlay() {
    final shouldShow = _showSuggestionDropdown();
    if (!shouldShow) {
      _removeSuggestionOverlay();
      return;
    }
    final overlay = Overlay.of(context, rootOverlay: true);
    if (_searchSuggestionOverlayEntry == null) {
      _searchSuggestionOverlayEntry = OverlayEntry(
        builder: (_) => _buildSuggestionOverlayEntry(),
      );
      overlay.insert(_searchSuggestionOverlayEntry!);
      return;
    }
    _searchSuggestionOverlayEntry!.markNeedsBuild();
  }

  void _removeSuggestionOverlay() {
    _searchSuggestionOverlayEntry?.remove();
    _searchSuggestionOverlayEntry = null;
  }

  Widget _buildSuggestionOverlayEntry() {
    final fabStyle = _rightSheetFabColors(context);
    final fieldContext = _searchHeaderFieldKey.currentContext;
    final renderObject = fieldContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached) {
      return const SizedBox.shrink();
    }
    final offset = renderObject.localToGlobal(Offset.zero);
    final size = renderObject.size;
    return Positioned(
      left: offset.dx,
      top: offset.dy + size.height + 4,
      width: size.width,
      child: Material(
        color: fabStyle.panel,
        elevation: 8,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: BoxDecoration(
            color: fabStyle.panel,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: fabStyle.border),
          ),
          child: _buildSuggestionDropdown(),
        ),
      ),
    );
  }

  String _normalizeState(String? raw) {
    final value = (raw ?? '').trim().toLowerCase();
    if (value == 'wrong') return 'wrong';
    if (value == 'unsolved') return 'unsolved';
    return 'correct';
  }

  void _hydrateSessionState({bool force = false}) {
    final session = widget.session;
    final nextId = session?.sessionId ?? '';
    if (!force && identical(session, _boundSessionRef)) return;
    _boundSessionRef = session;
    _boundSessionId = nextId;
    if (session == null) {
      _answerRenderRequestSeq++;
      _autoOpenedAnswerSessionId = '';
      setState(() {
        _gradingStates = <String, String>{};
        _baselineStates = <String, String>{};
        _correctionStates = <String, String>{};
        _correctionAttemptNumbers = <String, int>{};
        _gradingEditLocked = false;
        _wrongOnly = false;
        _answerRenders = <String, LearningProblemAnswerRender>{};
        _answerRenderFailedKeys = <String>{};
        _lastAnswerRenderRouteLogKey = '';
      });
      return;
    }
    final mapped = <String, String>{};
    session.initialStates.forEach((key, value) {
      mapped[key] = _normalizeState(value);
    });
    final baselineStates = <String, String>{};
    session.baselineStates.forEach((key, value) {
      final normalized = _normalizeState(value);
      if (normalized == 'wrong' || normalized == 'unsolved') {
        baselineStates[key] = normalized;
      }
    });
    final correctionStates = <String, String>{};
    session.initialCorrectionStates.forEach((key, value) {
      if (value.trim() == 'corrected' && baselineStates.containsKey(key)) {
        correctionStates[key] = 'corrected';
      }
    });
    baselineStates.forEach((key, _) {
      if (_normalizeState(mapped[key]) == 'correct') {
        correctionStates[key] = 'corrected';
      }
    });
    final correctionAttemptNumbers = <String, int>{};
    session.correctionAttemptNumbers.forEach((key, value) {
      if (value > 0 && correctionStates[key] == 'corrected') {
        correctionAttemptNumbers[key] = value;
      }
    });
    setState(() {
      _gradingStates = mapped;
      _baselineStates = baselineStates;
      _correctionStates = correctionStates;
      _correctionAttemptNumbers = correctionAttemptNumbers;
      _gradingEditLocked = session.gradingLocked;
      _wrongOnly = session.wrongOnlyDefault && baselineStates.isNotEmpty;
      _answerRenders = <String, LearningProblemAnswerRender>{};
      _answerRenderFailedKeys = <String>{};
      _lastAnswerRenderRouteLogKey = '';
    });
    unawaited(_loadAnswerRendersForSession(session));
    _scheduleAutoOpenSessionAnswer(session);
  }

  void _scheduleAutoOpenSessionAnswer(
      RightSideSheetTestGradingSession session) {
    final sessionId = session.sessionId.trim();
    if (sessionId.isEmpty ||
        session.answerPathRaw.trim().isEmpty ||
        _isProblemBankGradingSession(session) ||
        _autoOpenedAnswerSessionId == sessionId) {
      return;
    }
    _autoOpenedAnswerSessionId = sessionId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.session?.sessionId.trim() != sessionId) return;
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 220), () async {
          if (!mounted || widget.session?.sessionId.trim() != sessionId) return;
          final firstFocus = _firstAnswerPdfFocus(session);
          await _openSessionAnswerSheet(
            session,
            initialShowSolution: false,
            focusPageNumber: firstFocus.pageNumber,
            focusRect1k: firstFocus.rect1k,
          );
        }),
      );
    });
  }

  bool _isProblemBankGradingSession(RightSideSheetTestGradingSession session) {
    if (session.sessionId.contains('test_pb_grade')) return true;
    for (final rawPage in session.gradingPages) {
      final rawCells = rawPage['cells'];
      if (rawCells is! List) continue;
      for (final rawCell in rawCells) {
        if (rawCell is! Map) continue;
        final sourceKind =
            '${rawCell['answerSourceKind'] ?? rawCell['answer_source_kind'] ?? ''}'
                .trim()
                .toLowerCase();
        if (sourceKind == 'pb_question') return true;
      }
    }
    return false;
  }

  Future<String> _resolveActiveAcademyId() async {
    var academyId =
        (await TenantService.instance.getActiveAcademyId() ?? '').trim();
    if (academyId.isEmpty) {
      academyId = (await TenantService.instance.ensureActiveAcademy()).trim();
    }
    return academyId;
  }

  Future<void> _loadAnswerRendersForSession(
    RightSideSheetTestGradingSession session,
  ) async {
    final requestSeq = ++_answerRenderRequestSeq;
    final sourceIdsByLookup = <String, Set<String>>{};
    final cellKeysBySourceLookup = <String, List<String>>{};
    final expectedAssetKeys = <String>{};
    final missingSourceKeys = <String>{};
    for (final rawPage in session.gradingPages) {
      final rawCells = rawPage['cells'];
      if (rawCells is! List) continue;
      for (final rawCell in rawCells) {
        if (rawCell is! Map) continue;
        final key = '${rawCell['key'] ?? ''}'.trim();
        if (key.isEmpty) continue;
        final answer = '${rawCell['answer'] ?? ''}'.trim();
        final answerMode = '${rawCell['answerMode'] ?? rawCell['mode'] ?? ''}'
            .trim()
            .toLowerCase();
        if (_isObjectiveAnswer(answer: answer, answerMode: answerMode)) {
          continue;
        }
        final assetKind =
            '${rawCell['answerAssetKind'] ?? rawCell['answer_asset_kind'] ?? ''}'
                .trim()
                .toLowerCase();
        final answerImageUrl =
            '${rawCell['answerImageUrl'] ?? rawCell['answer_image_url'] ?? ''}'
                .trim();
        if (assetKind == 'raw_answer_image' && answerImageUrl.isNotEmpty) {
          continue;
        }
        expectedAssetKeys.add(key);
        final answerSourceKind =
            '${rawCell['answerSourceKind'] ?? rawCell['answer_source_kind'] ?? rawCell['sourceKind'] ?? rawCell['source_kind'] ?? ''}'
                .trim()
                .toLowerCase();
        final answerSourceId =
            '${rawCell['answerSourceId'] ?? rawCell['answer_source_id'] ?? rawCell['sourceId'] ?? rawCell['source_id'] ?? ''}'
                .trim();
        if (answerSourceKind.isNotEmpty && answerSourceId.isNotEmpty) {
          final answerKind = _answerRenderKindForRawCell(rawCell);
          final lookupKey = '$answerSourceKind\n$answerKind';
          sourceIdsByLookup
              .putIfAbsent(lookupKey, () => <String>{})
              .add(answerSourceId);
          cellKeysBySourceLookup
              .putIfAbsent('$lookupKey\n$answerSourceId', () => <String>[])
              .add(key);
        } else {
          missingSourceKeys.add(key);
        }
      }
    }
    if (expectedAssetKeys.isEmpty) {
      _debugLogAnswerRenderRoutesForSession(session);
      return;
    }
    try {
      final academyId = await _resolveActiveAcademyId();
      if (academyId.isEmpty) return;
      final storedRendersByKey = <String, LearningProblemAnswerRender>{};
      for (final entry in sourceIdsByLookup.entries) {
        final lookupParts = entry.key.split('\n');
        if (lookupParts.length != 2) continue;
        final sourceKind = lookupParts[0];
        final answerKind = lookupParts[1];
        final rendersBySourceId = await RightSheetAnswerPreloadService.instance
            .loadUnifiedAnswerRenderAssets(
          academyId: academyId,
          sourceKind: sourceKind,
          answerKind: answerKind,
          sourceIds: entry.value,
        );
        for (final renderEntry in rendersBySourceId.entries) {
          final cellKeys =
              cellKeysBySourceLookup['${entry.key}\n${renderEntry.key}'] ??
                  const <String>[];
          for (final cellKey in cellKeys) {
            storedRendersByKey[cellKey] = renderEntry.value;
          }
        }
      }
      final missingKeys = <String>{
        ...missingSourceKeys,
        ...expectedAssetKeys
            .where((key) => !storedRendersByKey.containsKey(key)),
      };
      if (!mounted ||
          requestSeq != _answerRenderRequestSeq ||
          widget.session?.sessionId != session.sessionId) {
        return;
      }
      setState(() {
        _answerRenders = storedRendersByKey;
        _answerRenderFailedKeys = missingKeys;
      });
      _debugLogAnswerRenderRoutesForSession(session);
    } catch (_) {
      if (!mounted ||
          requestSeq != _answerRenderRequestSeq ||
          widget.session?.sessionId != session.sessionId) {
        return;
      }
      setState(() {
        _answerRenders = <String, LearningProblemAnswerRender>{};
        _answerRenderFailedKeys = expectedAssetKeys;
      });
      _debugLogAnswerRenderRoutesForSession(session);
    }
  }

  String _answerRenderRouteForRawCell(Map rawCell) {
    final key = '${rawCell['key'] ?? ''}'.trim();
    final answer = '${rawCell['answer'] ?? ''}'.trim();
    final answerMode = '${rawCell['answerMode'] ?? rawCell['mode'] ?? ''}'
        .trim()
        .toLowerCase();
    if (_isObjectiveAnswer(answer: answer, answerMode: answerMode)) {
      return 'objective';
    }
    final assetKind =
        '${rawCell['answerAssetKind'] ?? rawCell['answer_asset_kind'] ?? ''}'
            .trim()
            .toLowerCase();
    final answerImageUrl =
        '${rawCell['answerImageUrl'] ?? rawCell['answer_image_url'] ?? ''}'
            .trim();
    if (assetKind == 'raw_answer_image' && answerImageUrl.isNotEmpty) {
      return 'raw_answer_image';
    }
    final render = _answerRenders[key];
    if (render != null && render.hasImage) {
      final style = render.styleVersion.trim();
      if (style == kUnifiedAnswerRenderStyleVersion) {
        return 'xelatex_asset';
      }
      return 'missing_xelatex_asset';
    }
    return 'missing_xelatex_asset';
  }

  void _debugLogAnswerRenderRoutesForSession(
    RightSideSheetTestGradingSession session,
  ) {
    if (!kDebugMode) return;
    final logKey =
        '${session.sessionId}|${_answerRenders.length}|${_answerRenderFailedKeys.length}';
    if (_lastAnswerRenderRouteLogKey == logKey) return;
    _lastAnswerRenderRouteLogKey = logKey;
    debugPrint(
      '[ANSWER_ROUTE] session=${session.sessionId} '
      'stored=${_answerRenders.length} failed=${_answerRenderFailedKeys.length}',
    );
    final routeRows = <({Map rawCell, String route})>[];
    for (final rawPage in session.gradingPages) {
      final rawCells = rawPage['cells'];
      if (rawCells is! List) continue;
      for (final rawCell in rawCells) {
        if (rawCell is! Map) continue;
        final key = '${rawCell['key'] ?? ''}'.trim();
        if (key.isEmpty) continue;
        routeRows.add(
            (rawCell: rawCell, route: _answerRenderRouteForRawCell(rawCell)));
      }
    }
    int routePriority(String route) {
      if (route == 'xelatex_asset') return 0;
      if (route == 'missing_xelatex_asset') return 1;
      if (route == 'raw_answer_image') return 2;
      if (route == 'objective') return 3;
      return 5;
    }

    routeRows.sort((a, b) {
      final byRoute = routePriority(a.route).compareTo(routePriority(b.route));
      if (byRoute != 0) return byRoute;
      return '${a.rawCell['questionIndex'] ?? ''}'
          .compareTo('${b.rawCell['questionIndex'] ?? ''}');
    });

    var shown = 0;
    for (final row in routeRows) {
      final rawCell = row.rawCell;
      final key = '${rawCell['key'] ?? ''}'.trim();
      final sourceKind =
          '${rawCell['answerSourceKind'] ?? rawCell['answer_source_kind'] ?? rawCell['sourceKind'] ?? rawCell['source_kind'] ?? ''}'
              .trim();
      final sourceId =
          '${rawCell['answerSourceId'] ?? rawCell['answer_source_id'] ?? rawCell['sourceId'] ?? rawCell['source_id'] ?? ''}'
              .trim();
      final render = _answerRenders[key];
      final style = render?.styleVersion.trim() ?? '';
      final width = render?.width;
      final height = render?.height;
      final effectivePixelRatio = render?.pixelRatio ?? 1.0;
      final displayHeight = render?.displayHeightDp ??
          (height == null
              ? null
              : _answerImageNaturalDisplayHeight(
                  rawHeight: height.toDouble(),
                  pixelRatio: effectivePixelRatio,
                ));
      final rowHeight = render?.rowHeightDp;
      debugPrint(
        '[ANSWER_ROUTE] cell=$shown route=${row.route} '
        'key=$key source=$sourceKind/$sourceId style=$style '
        'size=${width ?? '-'}x${height ?? '-'} pr=$effectivePixelRatio '
        'displayH=${displayHeight?.toStringAsFixed(1) ?? '-'} '
        'rowH=${rowHeight?.toStringAsFixed(1) ?? '-'}',
      );
      shown += 1;
      if (shown >= 12) return;
    }
  }

  Future<void> _loadRecentSearches() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final loaded = prefs.getStringList(_historyPrefKey) ?? const <String>[];
      if (!mounted) return;
      setState(() {
        _recentSearches = loaded
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .take(_historyLimit)
            .toList(growable: false);
      });
    } catch (_) {}
  }

  Future<void> _persistRecentSearches() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_historyPrefKey, _recentSearches);
    } catch (_) {}
  }

  Map<String, String> _decodeRecentSearch(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return const <String, String>{
        'query': '',
        'label': '',
        'studentName': '',
        'assignmentTitle': '',
        'assignmentCode': '',
        'studentId': '',
        'homeworkItemId': '',
      };
    }
    if (trimmed.startsWith('{')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map) {
          final query = '${decoded['query'] ?? ''}'.trim();
          final label = '${decoded['label'] ?? ''}'.trim();
          final studentName = '${decoded['studentName'] ?? ''}'.trim();
          final assignmentTitle = '${decoded['assignmentTitle'] ?? ''}'.trim();
          final assignmentCode = '${decoded['assignmentCode'] ?? ''}'.trim();
          final studentId = '${decoded['studentId'] ?? ''}'.trim();
          final homeworkItemId = '${decoded['homeworkItemId'] ?? ''}'.trim();
          return <String, String>{
            'query': query.isEmpty ? label : query,
            'label': label.isEmpty ? query : label,
            'studentName': studentName,
            'assignmentTitle': assignmentTitle,
            'assignmentCode': assignmentCode,
            'studentId': studentId,
            'homeworkItemId': homeworkItemId,
          };
        }
      } catch (_) {}
    }
    return <String, String>{
      'query': trimmed,
      'label': trimmed,
      'studentName': '',
      'assignmentTitle': '',
      'assignmentCode': '',
      'studentId': '',
      'homeworkItemId': '',
    };
  }

  String _encodeRecentSearch({
    required String query,
    required String label,
    String studentName = '',
    String assignmentTitle = '',
    String assignmentCode = '',
    String studentId = '',
    String homeworkItemId = '',
  }) {
    return jsonEncode(<String, String>{
      'query': query.trim(),
      'label': label.trim(),
      'studentName': studentName.trim(),
      'assignmentTitle': assignmentTitle.trim(),
      'assignmentCode': assignmentCode.trim(),
      'studentId': studentId.trim(),
      'homeworkItemId': homeworkItemId.trim(),
    });
  }

  String _recentSearchQuery(String raw) {
    return (_decodeRecentSearch(raw)['query'] ?? '').trim();
  }

  String _recentSearchLabel(String raw) {
    return (_decodeRecentSearch(raw)['label'] ?? '').trim();
  }

  String _recentSearchChipLabel(String raw) {
    final decoded = _decodeRecentSearch(raw);
    final studentName = (decoded['studentName'] ?? '').trim();
    final assignmentCode = (decoded['assignmentCode'] ?? '').trim();
    final query = (decoded['query'] ?? '').trim();
    final code = assignmentCode.isNotEmpty ? assignmentCode : query;
    if (studentName.isNotEmpty && code.isNotEmpty) {
      return '$studentName · $code';
    }
    if (studentName.isNotEmpty) return studentName;

    final label = (decoded['label'] ?? '').trim();
    if (label.isNotEmpty && label != query) return label;
    return query;
  }

  String _searchResultStudentName(RightSheetGradingSearchResult result) {
    final studentName = result.studentName.trim();
    return studentName.isEmpty ? '학생' : studentName;
  }

  String _searchResultTitle(RightSheetGradingSearchResult result) {
    final groupTitle = result.groupHomeworkTitle.trim();
    if (groupTitle.isNotEmpty) return groupTitle;
    final homeworkTitle = result.homeworkTitle.trim();
    return homeworkTitle.isEmpty ? '과제' : homeworkTitle;
  }

  String _searchResultRecentLabel(RightSheetGradingSearchResult result) {
    final code = result.assignmentCode.trim();
    if (code.isEmpty) return _searchResultStudentName(result);
    return '${_searchResultStudentName(result)} · $code'.trim();
  }

  RightSheetGradingSearchResult? _pickResultForRecentSearch(
    List<RightSheetGradingSearchResult> results,
    String term,
  ) {
    if (results.isEmpty) return null;
    if (results.length == 1) return results.single;

    final normalizedTerm = term.trim().toLowerCase();
    if (normalizedTerm.isEmpty) return results.first;

    final codeMatches = results.where((result) {
      final code = result.assignmentCode.trim().toLowerCase();
      if (code.isEmpty) return false;
      return code == normalizedTerm || code.endsWith(normalizedTerm);
    }).toList(growable: false);
    if (codeMatches.length == 1) return codeMatches.single;

    return results.first;
  }

  List<String>? _recentSearchEntryFromResult({
    required String query,
    required RightSheetGradingSearchResult result,
  }) {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) return null;
    return _mergeRecentSearch(
      query: normalizedQuery,
      label: _searchResultRecentLabel(result),
      studentName: _searchResultStudentName(result),
      assignmentTitle: _searchResultTitle(result),
      assignmentCode: result.assignmentCode.trim(),
      studentId: result.studentId.trim(),
      homeworkItemId: result.homeworkItemId.trim(),
      dedupeTerms: <String>{
        _searchResultTitle(result),
        _searchResultStudentName(result),
        result.assignmentCode.trim(),
        result.homeworkItemId.trim(),
      },
    );
  }

  Future<void> _hydrateRecentSearchLabels() async {
    final searchAction = rightSheetGradingSearchRunAction;
    if (searchAction == null || _recentSearches.isEmpty) return;

    var changed = false;
    final updated = <String>[];
    for (final raw in _recentSearches) {
      final decoded = _decodeRecentSearch(raw);
      final studentName = (decoded['studentName'] ?? '').trim();
      final assignmentTitle = (decoded['assignmentTitle'] ?? '').trim();
      if (studentName.isNotEmpty && assignmentTitle.isNotEmpty) {
        updated.add(raw);
        continue;
      }

      final query = _recentSearchQuery(raw);
      if (query.isEmpty) {
        updated.add(raw);
        continue;
      }

      try {
        final results = await searchAction(query);
        final picked = _pickResultForRecentSearch(results, query);
        if (picked != null) {
          updated.add(
            _encodeRecentSearch(
              query: query,
              label: _searchResultRecentLabel(picked),
              studentName: _searchResultStudentName(picked),
              assignmentTitle: _searchResultTitle(picked),
              assignmentCode: picked.assignmentCode.trim(),
              studentId: picked.studentId.trim(),
              homeworkItemId: picked.homeworkItemId.trim(),
            ),
          );
          changed = true;
        } else {
          updated.add(raw);
        }
      } catch (_) {
        updated.add(raw);
      }
    }

    if (!changed || !mounted) return;
    setState(() {
      _recentSearches = updated.take(_historyLimit).toList(growable: false);
    });
    await _persistRecentSearches();
  }

  List<String> _mergeRecentSearch({
    required String query,
    required String label,
    String studentName = '',
    String assignmentTitle = '',
    String assignmentCode = '',
    String studentId = '',
    String homeworkItemId = '',
    Set<String> dedupeTerms = const <String>{},
  }) {
    final normalizedQuery = query.trim();
    final normalizedLabel = label.trim();
    final normalizedStudent = studentName.trim();
    final normalizedTitle = assignmentTitle.trim();
    final normalizedCode = assignmentCode.trim();
    final normalizedStudentId = studentId.trim();
    final normalizedHomeworkItemId = homeworkItemId.trim();
    if (normalizedQuery.isEmpty && normalizedLabel.isEmpty) {
      return _recentSearches;
    }
    final entryQuery =
        normalizedQuery.isEmpty ? normalizedLabel : normalizedQuery;
    final entryLabel = normalizedLabel.isEmpty
        ? (normalizedStudent.isNotEmpty && normalizedTitle.isNotEmpty
            ? '$normalizedStudent · $normalizedTitle'
            : normalizedQuery)
        : normalizedLabel;
    final entry = _encodeRecentSearch(
      query: entryQuery,
      label: entryLabel,
      studentName: normalizedStudent,
      assignmentTitle: normalizedTitle,
      assignmentCode: normalizedCode,
      studentId: normalizedStudentId,
      homeworkItemId: normalizedHomeworkItemId,
    );
    final dedupeKeys = <String>{
      entryQuery.toLowerCase(),
      entryLabel.toLowerCase(),
      ...dedupeTerms.map((e) => e.trim().toLowerCase()).where(
            (e) => e.isNotEmpty,
          ),
    };
    final next = <String>[entry];
    for (final existing in _recentSearches) {
      final existingQuery = _recentSearchQuery(existing).toLowerCase();
      final existingLabel = _recentSearchLabel(existing).toLowerCase();
      final existingDecoded = _decodeRecentSearch(existing);
      final existingHomeworkItemId =
          (existingDecoded['homeworkItemId'] ?? '').trim().toLowerCase();
      if (dedupeKeys.contains(existingQuery) ||
          dedupeKeys.contains(existingLabel) ||
          dedupeKeys.contains(existingHomeworkItemId)) {
        continue;
      }
      next.add(existing);
      if (next.length >= _historyLimit) break;
    }
    return next;
  }

  Future<void> _rememberSearchResult(
    RightSheetGradingSearchResult result,
  ) async {
    final title = _searchResultTitle(result);
    final studentName = _searchResultStudentName(result);
    final label = _searchResultRecentLabel(result);
    final code = result.assignmentCode.trim();
    final query = code.isEmpty ? label : code;
    if (!mounted) return;
    setState(() {
      _recentSearches = _mergeRecentSearch(
        query: query,
        label: label,
        studentName: studentName,
        assignmentTitle: title,
        dedupeTerms: <String>{title, studentName},
      );
    });
    await _persistRecentSearches();
  }

  String _nextState(String current) {
    switch (_normalizeState(current)) {
      case 'correct':
        return 'wrong';
      case 'wrong':
        return 'unsolved';
      case 'unsolved':
        return 'correct';
      default:
        return 'correct';
    }
  }

  void _emitStateChanged() {
    widget.session?.onStatesChanged?.call(
      Map<String, String>.from(_gradingStates),
    );
  }

  bool _isBaselineRetryKey(String key) {
    final state = _baselineStates[key];
    return state == 'wrong' || state == 'unsolved';
  }

  bool _isCorrectedRetryKey(String key) {
    return _correctionStates[key] == 'corrected' && _isBaselineRetryKey(key);
  }

  bool get _answerListReadOnly => widget.session?.onAction == null;

  Future<void> _toggleCellState(String key) async {
    if (_answerListReadOnly) return;
    if (_gradingEditLocked && _isBaselineRetryKey(key)) {
      setState(() {
        if (_isCorrectedRetryKey(key)) {
          _correctionStates.remove(key);
          _gradingStates[key] = _baselineStates[key] ?? 'wrong';
        } else {
          _gradingStates[key] = 'correct';
          _correctionStates[key] = 'corrected';
        }
      });
      _emitStateChanged();
      return;
    }
    if (_gradingEditLocked) {
      final unlocked = await _confirmResetForEdit();
      if (!unlocked || !mounted) return;
    }
    setState(() {
      final current = _normalizeState(_gradingStates[key]);
      final next = _nextState(current);
      _gradingStates[key] = next;
      if (_isBaselineRetryKey(key)) {
        if (next == 'correct') {
          _correctionStates[key] = 'corrected';
        } else {
          _correctionStates.remove(key);
        }
      }
    });
    _emitStateChanged();
  }

  Future<bool> _confirmResetForEdit() async {
    final session = widget.session;
    if (session == null || _editResetBusy) return false;
    final confirmed = await showDialog<bool>(
      context: _navigatorContext,
      useRootNavigator: true,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: _rsPanelBg,
          title: const Text(
            '채점 결과를 수정할까요?',
            style: TextStyle(
              color: _rsText,
              fontWeight: FontWeight.w900,
            ),
          ),
          content: const Text(
            '이미 저장된 첫 채점 결과가 있습니다.\n수정하면 저장된 점수와 오답 기록이 리셋되고, 다시 확인할 때 새 결과로 저장됩니다.',
            style: TextStyle(
              color: _rsTextSub,
              fontWeight: FontWeight.w700,
              height: 1.45,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.of(dialogContext, rootNavigator: true).pop(false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext, rootNavigator: true).pop(true),
              child: const Text('수정하고 리셋'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return false;
    setState(() {
      _editResetBusy = true;
    });
    var ok = true;
    try {
      final resetAction = session.onRequestEditReset;
      if (resetAction != null) {
        ok = await resetAction();
      }
    } finally {
      if (mounted) {
        setState(() {
          _editResetBusy = false;
        });
      }
    }
    if (!ok || !mounted) return false;
    setState(() {
      _gradingEditLocked = false;
      _gradingStates = <String, String>{};
      _baselineStates = <String, String>{};
      _correctionStates = <String, String>{};
      _correctionAttemptNumbers = <String, int>{};
      _wrongOnly = false;
    });
    _emitStateChanged();
    return true;
  }

  /// 오버플로 정답 리스트 전용 변환.
  /// - 한글은 plain text, 비한글 수학 토큰은 인라인 `\(...\)` 조각으로 잘게 쪼개
  ///   `LatexTextRenderer` 의 `RichText` 가 토큰 경계에서 자연스럽게 줄바꿈하도록 한다.
  /// - 분수는 `\displaystyle\dfrac{..}{..}` 로 승격 → XELATEX "빠른정답" 과 동일한 2D 스택.
  /// - 폭이 좁아 한 줄에 못 들어가면 가로 스크롤/축소 없이 그냥 다음 줄로 내려간다.
  String _normalizeAnswerForOverflowDisplay(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '-';
    if (trimmed == '-') return trimmed;
    return _overflowAnswerMarkup(trimmed);
  }

  // --- 이하 헬퍼들은 모두 긴 정답 리스트 전용.

  /// LaTeX 로 바뀌지 못한 채 저장된 흔한 케이스들을 복구.
  /// - 유니코드 연산자: `×`, `÷`, `≤`, `≥`, `·` → `\times`, `\div`, ...
  /// - OCR/수동 입력에서 종종 섞여 들어오는 literal `TIMES`, `\mathrm{TIMES}`,
  ///   `\text{TIMES}`, `\operatorname{TIMES}` 등도 `\times` 로 복구.
  /// - 토큰화가 가능하도록 핵심 연산자 주변 공백을 보정한다.
  String _rsPreprocessOverflowRaw(String raw) {
    var s = raw.replaceAll('\n', ' ').replaceAll('\r', ' ');
    const opMap = <String, String>{
      '×': r' \times ',
      '÷': r' \div ',
      '·': r' \cdot ',
      '≤': r' \le ',
      '≥': r' \ge ',
      '≠': r' \ne ',
      '±': r' \pm ',
    };
    for (final e in opMap.entries) {
      s = s.replaceAll(e.key, e.value);
    }
    s = s.replaceAllMapped(
      RegExp(r'\\(?:mathrm|text|operatorname)\s*\{\s*TIMES\s*\}'),
      (_) => r' \times ',
    );
    s = s.replaceAllMapped(
      RegExp(r'\\(?:mathrm|text|operatorname)\s*\{\s*DIV\s*\}'),
      (_) => r' \div ',
    );
    s = s.replaceAllMapped(
      RegExp(r'(?<![A-Za-z\\])TIMES(?![A-Za-z])'),
      (_) => r' \times ',
    );
    s = s.replaceAllMapped(
      RegExp(r'(?<![A-Za-z\\])DIV(?![A-Za-z])'),
      (_) => r' \div ',
    );
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }

  /// 토큰 분리가 가능하도록 핵심 경계 앞뒤에 공백을 강제 주입.
  /// 괄호/중괄호 깊이를 추적하지 않고 단순 치환이지만, 주어진 경계 문자들은
  /// LaTeX 문법상 토큰 바깥에서만 나타나므로 안전하다.
  String _rsInsertSplittableSpaces(String input) {
    var s = input;
    s = s.replaceAllMapped(RegExp(r','), (_) => ' , ');
    s = s.replaceAllMapped(RegExp(r';'), (_) => ' ; ');
    s = s.replaceAllMapped(RegExp(r'='), (_) => ' = ');
    s = s.replaceAllMapped(
        RegExp(r'(?<![A-Za-z])\\times(?![A-Za-z])'), (_) => r' \times ');
    s = s.replaceAllMapped(
        RegExp(r'(?<![A-Za-z])\\div(?![A-Za-z])'), (_) => r' \div ');
    s = s.replaceAllMapped(
        RegExp(r'(?<![A-Za-z])\\cdot(?![A-Za-z])'), (_) => r' \cdot ');
    s = s.replaceAllMapped(
        RegExp(r'(?<![A-Za-z])\\pm(?![A-Za-z])'), (_) => r' \pm ');
    s = s.replaceAllMapped(
        RegExp(r'(?<![A-Za-z])\\le(?![A-Za-z])'), (_) => r' \le ');
    s = s.replaceAllMapped(
        RegExp(r'(?<![A-Za-z])\\ge(?![A-Za-z])'), (_) => r' \ge ');
    s = s.replaceAllMapped(
        RegExp(r'(?<![A-Za-z])\\ne(?![A-Za-z])'), (_) => r' \ne ');
    // `)(` 또는 `)`+숫자/영문 → 공백 주입 (중괄호 안은 건드리지 않기 위해 단순)
    s = s.replaceAllMapped(RegExp(r'\)(?=[A-Za-z0-9\\])'), (_) => ') ');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }

  /// 중괄호 깊이를 추적하며 최상위 공백에서만 토큰을 분리.
  List<String> _rsSplitTopLevelTokens(String s) {
    final out = <String>[];
    final buf = StringBuffer();
    var braceDepth = 0;
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (c == '{') braceDepth += 1;
      if (c == '}') braceDepth = braceDepth > 0 ? braceDepth - 1 : 0;
      if (c == ' ' && braceDepth == 0) {
        final token = buf.toString();
        if (token.isNotEmpty) out.add(token);
        buf.clear();
      } else {
        buf.write(c);
      }
    }
    final tail = buf.toString();
    if (tail.isNotEmpty) out.add(tail);
    return out;
  }

  String _overflowAnswerMarkup(String raw) {
    final preprocessed = _rsPreprocessOverflowRaw(raw);
    if (preprocessed.isEmpty) return '';
    final buffer = StringBuffer();
    int lastIndex = 0;
    final nonKorean = RegExp(r'[^가-힣]+');
    for (final match in nonKorean.allMatches(preprocessed)) {
      if (match.start > lastIndex) {
        buffer.write(preprocessed.substring(lastIndex, match.start));
      }
      final segment = preprocessed.substring(match.start, match.end);
      final core = segment.trim();
      final leading = segment.startsWith(' ') ? ' ' : '';
      final trailing = segment.endsWith(' ') && segment.length > 1 ? ' ' : '';
      if (core.isEmpty) {
        buffer.write(segment);
        lastIndex = match.end;
        continue;
      }
      buffer.write(leading);
      buffer.write(_rsBuildTokenizedMathMarkup(core));
      buffer.write(trailing);
      lastIndex = match.end;
    }
    if (lastIndex < preprocessed.length) {
      buffer.write(preprocessed.substring(lastIndex));
    }
    return buffer.toString();
  }

  String _rsPromoteFractionsForOverflow(String latex) {
    var out = latex;
    out = out.replaceAllMapped(
      RegExp(r'\\(?:dfrac|tfrac|frac)\s*(?=\{)'),
      (_) => r'\dfrac',
    );
    out = out.replaceAllMapped(
      RegExp(r'(?<![\\\w])(-?\d+(?:\.\d+)?)\s*/\s*(-?\d+(?:\.\d+)?)(?![\w])'),
      (m) => r'\dfrac{' + (m.group(1) ?? '') + '}{' + (m.group(2) ?? '') + '}',
    );
    return out;
  }

  bool _rsLooksLikeMathCandidate(String raw) {
    final input = raw.trim();
    if (input.isEmpty) return false;
    if (RegExp(r'[가-힣]').hasMatch(input)) return false;
    return RegExp(r'[A-Za-z0-9=^_{}\\]|\\times|\\over|\\le|\\ge|\\frac|\\dfrac')
        .hasMatch(input);
  }

  void _rsAppendMathToken(StringBuffer buffer, String latex) {
    final hasFraction = latex.contains(r'\frac') ||
        latex.contains(r'\dfrac') ||
        latex.contains(r'\tfrac');
    if (hasFraction) {
      buffer.write(r'\(\displaystyle ');
      buffer.write(latex);
      buffer.write(r'\)');
      return;
    }
    buffer.write(r'\(');
    buffer.write(latex);
    buffer.write(r'\)');
  }

  /// 연속된 비한글 구간(`segment`) 을 토큰 단위로 인라인 `\(..\)` 로 감싼다.
  /// - 연산자 주변에 공백을 강제 주입 → 최상위 공백 경계에서 분할.
  /// - 각 토큰 단위로 분수 승격 후 개별 `\(..\)` 로 래핑 → RichText 가 토큰
  ///   경계에서 줄바꿈할 수 있도록 한다. (`softWrap: true`)
  String _rsBuildTokenizedMathMarkup(String segment) {
    final spaced = _rsInsertSplittableSpaces(segment);
    final tokens = _rsSplitTopLevelTokens(spaced);
    if (tokens.isEmpty) return '';
    final pieces = <String>[];
    for (final rawToken in tokens) {
      final token = rawToken.trim();
      if (token.isEmpty) continue;
      final latex = _rsPromoteFractionsForOverflow(token);
      final isOperatorToken = RegExp(
        r'^(?:=|,|;|:|[+\-*/<>]|\\times|\\div|\\cdot|\\pm|\\le|\\ge|\\ne)+$',
      ).hasMatch(token);
      final tokenIsMath = isOperatorToken || _rsLooksLikeMathCandidate(token);
      if (tokenIsMath) {
        final sb = StringBuffer();
        _rsAppendMathToken(sb, latex);
        pieces.add(sb.toString());
      } else {
        pieces.add(latex);
      }
    }
    return pieces.join(' ');
  }

  String _normalizeSearchToken(String raw) {
    return raw.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
  }

  bool _isSuggestionQuery(String raw) {
    final token = _normalizeSearchToken(raw.trim());
    return token.length >= 2;
  }

  void _clearSearchSuggestions({bool clearError = true}) {
    _searchSuggestDebounce?.cancel();
    _searchSuggestRequestSeq += 1;
    if (!mounted) return;
    setState(() {
      _searchSuggestions = const <RightSheetGradingSearchResult>[];
      _searchSuggestBusy = false;
      if (clearError) {
        _searchSuggestError = null;
      }
    });
    _scheduleSuggestionOverlaySync();
  }

  void _scheduleSuggestionSearch(String raw) {
    _searchSuggestDebounce?.cancel();
    final term = raw.trim();
    if (term.isEmpty || !_isSuggestionQuery(term)) {
      _searchSuggestRequestSeq += 1;
      if (!mounted) return;
      setState(() {
        _searchSuggestions = const <RightSheetGradingSearchResult>[];
        _searchSuggestBusy = false;
        _searchSuggestError = null;
      });
      _scheduleSuggestionOverlaySync();
      return;
    }
    _searchSuggestDebounce = Timer(
      const Duration(milliseconds: _suggestDebounceMs),
      () => unawaited(_runSuggestionSearch(term)),
    );
  }

  Future<void> _runSuggestionSearch(String term) async {
    final suggestAction = rightSheetGradingSearchSuggestAction;
    if (!_isSuggestionQuery(_searchCtrl.text)) {
      _clearSearchSuggestions();
      return;
    }
    if (suggestAction == null) {
      if (!mounted) return;
      setState(() {
        _searchSuggestions = const <RightSheetGradingSearchResult>[];
        _searchSuggestBusy = false;
        _searchSuggestError = null;
      });
      _scheduleSuggestionOverlaySync();
      return;
    }

    final requestId = ++_searchSuggestRequestSeq;
    if (!mounted) return;
    setState(() {
      _searchSuggestBusy = true;
      _searchSuggestError = null;
    });
    _scheduleSuggestionOverlaySync();

    try {
      final suggestions = await suggestAction(term);
      if (!mounted || requestId != _searchSuggestRequestSeq) return;
      if (!_isSuggestionQuery(_searchCtrl.text)) {
        setState(() {
          _searchSuggestions = const <RightSheetGradingSearchResult>[];
          _searchSuggestBusy = false;
        });
        _scheduleSuggestionOverlaySync();
        return;
      }
      setState(() {
        _searchSuggestions = suggestions.length <= 5
            ? suggestions
            : const <RightSheetGradingSearchResult>[];
        _searchSuggestBusy = false;
        _searchSuggestError = null;
      });
      _scheduleSuggestionOverlaySync();
    } catch (e) {
      if (!mounted || requestId != _searchSuggestRequestSeq) return;
      setState(() {
        _searchSuggestions = const <RightSheetGradingSearchResult>[];
        _searchSuggestBusy = false;
        _searchSuggestError = '추천 조회 중 오류가 발생했습니다: $e';
      });
      _scheduleSuggestionOverlaySync();
    }
  }

  Future<void> _submitSearch([String? seeded]) async {
    _searchSuggestDebounce?.cancel();
    _searchSuggestRequestSeq += 1;
    final term = (seeded ?? _searchCtrl.text).trim();
    if (term.isEmpty) {
      if (!mounted) return;
      setState(() {
        _searchSuggestions = const <RightSheetGradingSearchResult>[];
        _searchSuggestBusy = false;
        _searchSuggestError = null;
        _searchResults = const <RightSheetGradingSearchResult>[];
        _searchError = null;
      });
      _scheduleSuggestionOverlaySync();
      return;
    }
    final next = _mergeRecentSearch(query: term, label: term);
    setState(() {
      _searchCtrl.text = term;
      _searchCtrl.selection = TextSelection.collapsed(offset: term.length);
      _recentSearches = next;
      _searchSuggestions = const <RightSheetGradingSearchResult>[];
      _searchSuggestBusy = false;
      _searchSuggestError = null;
      _searchBusy = true;
      _searchError = null;
    });
    _scheduleSuggestionOverlaySync();
    await _persistRecentSearches();

    final searchAction = rightSheetGradingSearchRunAction;
    if (searchAction == null) {
      if (!mounted) return;
      setState(() {
        _searchResults = const <RightSheetGradingSearchResult>[];
        _searchBusy = false;
        _searchError = '검색 기능이 아직 준비되지 않았습니다.';
      });
      _scheduleSuggestionOverlaySync();
      return;
    }

    try {
      final results = await searchAction(term);
      if (!mounted) return;
      final picked = _pickResultForRecentSearch(results, term);
      final promotedRecent = picked == null
          ? null
          : _recentSearchEntryFromResult(query: term, result: picked);
      setState(() {
        if (promotedRecent != null) {
          _recentSearches = promotedRecent;
        }
        _searchResults = results;
        _searchBusy = false;
        _searchError = null;
      });
      if (promotedRecent != null) {
        await _persistRecentSearches();
      }
      _scheduleSuggestionOverlaySync();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searchResults = const <RightSheetGradingSearchResult>[];
        _searchBusy = false;
        _searchError = '검색 중 오류가 발생했습니다: $e';
      });
      _scheduleSuggestionOverlaySync();
    }
  }

  Future<void> _openSearchResult(RightSheetGradingSearchResult result) async {
    final openAction = rightSheetGradingSearchOpenAction;
    if (openAction == null || _searchOpenBusy) return;
    setState(() {
      _searchOpenBusy = true;
      _searchError = null;
    });
    _scheduleSuggestionOverlaySync();
    try {
      await _rememberSearchResult(result);
      await openAction(result);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searchError = '결과 열기에 실패했습니다: $e';
      });
      _scheduleSuggestionOverlaySync();
    } finally {
      if (!mounted) return;
      setState(() {
        _searchOpenBusy = false;
      });
      _scheduleSuggestionOverlaySync();
    }
  }

  Future<void> _openRecentSearch(String raw) async {
    final openAction = rightSheetGradingSearchOpenAction;
    if (openAction == null || _searchOpenBusy) return;

    final decoded = _decodeRecentSearch(raw);
    final query = (decoded['query'] ?? '').trim();
    final studentId = (decoded['studentId'] ?? '').trim();
    final homeworkItemId = (decoded['homeworkItemId'] ?? '').trim();
    final assignmentCode = (decoded['assignmentCode'] ?? '').trim();
    final studentName = (decoded['studentName'] ?? '').trim();
    final assignmentTitle = (decoded['assignmentTitle'] ?? '').trim();

    RightSheetGradingSearchResult? result;
    if (studentId.isNotEmpty && homeworkItemId.isNotEmpty) {
      result = RightSheetGradingSearchResult(
        studentId: studentId,
        homeworkItemId: homeworkItemId,
        assignmentCode: assignmentCode.isEmpty ? query : assignmentCode,
        studentName: studentName,
        groupHomeworkTitle: assignmentTitle,
        homeworkTitle: assignmentTitle,
        hasTextbookLink: false,
        isTestHomework: false,
        isSubmitted: false,
      );
    } else {
      final searchAction = rightSheetGradingSearchRunAction;
      if (searchAction == null || query.isEmpty) return;
      setState(() {
        _searchBusy = true;
        _searchError = null;
      });
      _scheduleSuggestionOverlaySync();
      try {
        final results = await searchAction(query);
        if (!mounted) return;
        result = _pickResultForRecentSearch(results, query);
      } finally {
        if (mounted) {
          setState(() {
            _searchBusy = false;
          });
        }
      }
    }

    if (result == null) {
      if (!mounted) return;
      setState(() {
        _searchError = '최근 검색 과제를 찾지 못했습니다.';
      });
      _scheduleSuggestionOverlaySync();
      return;
    }
    await _openSearchResult(result);
  }

  Future<void> _removeRecentAt(int index) async {
    if (index < 0 || index >= _recentSearches.length) return;
    final next = List<String>.of(_recentSearches)..removeAt(index);
    setState(() {
      _recentSearches = next;
    });
    await _persistRecentSearches();
  }

  Future<void> _clearRecentSearches() async {
    setState(() {
      _recentSearches = <String>[];
    });
    await _persistRecentSearches();
  }

  Future<void> _runAction(String action) async {
    final session = widget.session;
    if (session == null || _actionBusy) return;
    setState(() {
      _actionBusy = true;
    });
    _emitStateChanged();
    try {
      await session.onAction?.call(
        action,
        Map<String, String>.from(_gradingStates),
        Map<String, String>.from(_correctionStates),
      );
      widget.onClearSession();
      if (session.closeSheetOnAction) {
        final closeAction = closeRightSideSheetAction;
        if (closeAction != null) {
          await closeAction();
        }
      }
    } finally {
      if (!mounted) return;
      setState(() {
        _actionBusy = false;
      });
    }
  }

  List<_RightSheetGradingPageVm> _visiblePages() {
    final session = widget.session;
    if (session == null) return const <_RightSheetGradingPageVm>[];
    final pages = <_RightSheetGradingPageVm>[];
    for (final rawPage in session.gradingPages) {
      final pageNumber = (rawPage['pageNumber'] is int)
          ? rawPage['pageNumber'] as int
          : int.tryParse('${rawPage['pageNumber']}') ?? 1;
      final rawCells = rawPage['cells'];
      if (rawCells is! List) continue;
      final parsedCells = <_RightSheetGradingCellVm>[];
      for (final rawCell in rawCells) {
        if (rawCell is! Map) continue;
        final key = '${rawCell['key'] ?? ''}'.trim();
        if (key.isEmpty) continue;
        if (_wrongOnly &&
            (!_isBaselineRetryKey(key) || _isCorrectedRetryKey(key))) {
          continue;
        }
        final questionIndex = (rawCell['questionIndex'] is int)
            ? rawCell['questionIndex'] as int
            : int.tryParse('${rawCell['questionIndex']}') ?? 0;
        final questionLabel =
            '${rawCell['questionLabel'] ?? rawCell['question_label'] ?? ''}'
                .trim();
        final answer = '${rawCell['answer'] ?? ''}'.trim();
        final answerMode = '${rawCell['answerMode'] ?? rawCell['mode'] ?? ''}'
            .trim()
            .toLowerCase();
        final answerImageUrl =
            '${rawCell['answerImageUrl'] ?? rawCell['answer_image_url'] ?? ''}'
                .trim();
        int? parsePositiveInt(dynamic raw) {
          final value = raw is int ? raw : int.tryParse('$raw');
          return value != null && value > 0 ? value : null;
        }

        double? parsePositiveDouble(dynamic raw) {
          final value = raw is num ? raw.toDouble() : double.tryParse('$raw');
          return value != null && value > 0 ? value : null;
        }

        List<int> parseRect1k(dynamic raw) {
          final source = raw is String
              ? (() {
                  try {
                    return jsonDecode(raw);
                  } catch (_) {
                    return raw
                        .split(RegExp(r'[, ]+'))
                        .where((part) => part.trim().isNotEmpty)
                        .toList();
                  }
                })()
              : raw;
          if (source is! List) return const <int>[];
          final values = source
              .map((entry) => entry is int ? entry : int.tryParse('$entry'))
              .whereType<int>()
              .toList(growable: false);
          return values.length >= 4 ? values.take(4).toList() : const <int>[];
        }

        Map<String, String> parseStringMap(dynamic raw) {
          dynamic source = raw;
          if (source is String) {
            try {
              source = jsonDecode(source);
            } catch (_) {
              return const <String, String>{};
            }
          }
          if (source is! Map) return const <String, String>{};
          final out = <String, String>{};
          source.forEach((key, value) {
            final outKey = '$key'.trim();
            final outValue = '$value'.trim();
            if (outKey.isNotEmpty && outValue.isNotEmpty) {
              out[outKey] = outValue;
            }
          });
          return out;
        }

        parsedCells.add(
          _RightSheetGradingCellVm(
            key: key,
            questionIndex:
                questionIndex <= 0 ? (parsedCells.length + 1) : questionIndex,
            questionLabel: questionLabel,
            answer: answer,
            answerMode: answerMode,
            answerImageUrl: answerImageUrl,
            answerImageWidth: parsePositiveInt(
              rawCell['answerImageWidth'] ?? rawCell['answer_image_width_px'],
            ),
            answerImageHeight: parsePositiveInt(
              rawCell['answerImageHeight'] ?? rawCell['answer_image_height_px'],
            ),
            answerImagePixelRatio: parsePositiveDouble(
              rawCell['answerImagePixelRatio'] ??
                  rawCell['answer_image_pixel_ratio'] ??
                  rawCell['answerRenderPixelRatio'] ??
                  rawCell['answer_render_pixel_ratio'],
            ),
            answerRenderPolicy:
                '${rawCell['answerRenderPolicy'] ?? rawCell['answer_render_policy'] ?? ''}'
                    .trim()
                    .toLowerCase(),
            answerSourceKind:
                '${rawCell['answerSourceKind'] ?? rawCell['answer_source_kind'] ?? rawCell['sourceKind'] ?? rawCell['source_kind'] ?? ''}'
                    .trim()
                    .toLowerCase(),
            answerSourceId:
                '${rawCell['answerSourceId'] ?? rawCell['answer_source_id'] ?? rawCell['sourceId'] ?? rawCell['source_id'] ?? ''}'
                    .trim(),
            answerAssetKind:
                '${rawCell['answerAssetKind'] ?? rawCell['answer_asset_kind'] ?? ''}'
                    .trim()
                    .toLowerCase(),
            answerRenderStyleVersion:
                '${rawCell['answerRenderStyleVersion'] ?? rawCell['answer_render_style_version'] ?? ''}'
                    .trim(),
            answerPageNumber: parsePositiveInt(
              rawCell['answerPageNumber'] ??
                  rawCell['answer_page_number'] ??
                  rawCell['answerRawPage'] ??
                  rawCell['answer_raw_page'] ??
                  rawCell['answerDisplayPage'] ??
                  rawCell['answer_display_page'],
            ),
            answerRect1k: parseRect1k(
              rawCell['answerRect1k'] ??
                  rawCell['answer_rect_1k'] ??
                  rawCell['answerBbox1k'] ??
                  rawCell['answer_bbox_1k'],
            ),
            focusRect1k: parseRect1k(
              rawCell['focusRect1k'] ??
                  rawCell['focus_rect_1k'] ??
                  rawCell['itemRegion1k'] ??
                  rawCell['item_region_1k'] ??
                  rawCell['bbox1k'] ??
                  rawCell['bbox_1k'],
            ),
            answerPathRaw:
                '${rawCell['answerPathRaw'] ?? rawCell['answer_path_raw'] ?? ''}'
                    .trim(),
            solutionPathRaw:
                '${rawCell['solutionPathRaw'] ?? rawCell['solution_path_raw'] ?? ''}'
                    .trim(),
            solutionPageNumber: parsePositiveInt(
              rawCell['solutionPageNumber'] ??
                  rawCell['solution_page_number'] ??
                  rawCell['solutionRawPage'] ??
                  rawCell['solution_raw_page'] ??
                  rawCell['solutionDisplayPage'] ??
                  rawCell['solution_display_page'],
            ),
            solutionRect1k: parseRect1k(
              rawCell['solutionRect1k'] ??
                  rawCell['solution_rect_1k'] ??
                  rawCell['solutionNumberRegion1k'] ??
                  rawCell['solution_number_region_1k'] ??
                  rawCell['solutionContentRegion1k'] ??
                  rawCell['solution_content_region_1k'],
            ),
            sourceInfo: parseStringMap(
              rawCell['sourceInfo'] ?? rawCell['source_info'],
            ),
          ),
        );
      }
      if (parsedCells.isEmpty) continue;
      parsedCells.sort((a, b) => a.questionIndex.compareTo(b.questionIndex));
      pages.add(
        _RightSheetGradingPageVm(
          pageNumber: pageNumber <= 0 ? 1 : pageNumber,
          cells: parsedCells,
        ),
      );
    }
    pages.sort((a, b) => a.pageNumber.compareTo(b.pageNumber));
    return pages;
  }

  bool _showSuggestionDropdown() {
    final query = _searchCtrl.text.trim();
    if (!_isSuggestionQuery(query)) return false;
    if (_searchDropdownTapInProgress) return true;
    return _searchFocus.hasFocus;
  }

  Widget _buildSuggestionDropdownItem(RightSheetGradingSearchResult result) {
    final fabStyle = _rightSheetFabColors(context);
    final code = result.assignmentCode.trim().isEmpty
        ? '-'
        : result.assignmentCode.trim();
    final canOpen = result.isTestHomework || result.hasTextbookLink;
    final subtitle = [
      _searchResultTitle(result),
      if (code != '-') code,
    ].join(' · ');
    return InkWell(
      onTapDown: (_) {
        _searchBlurHideTimer?.cancel();
        _setSearchDropdownTapInProgress(true);
      },
      onTapCancel: () {
        _setSearchDropdownTapInProgress(false);
      },
      onTap: !_searchOpenBusy
          ? () {
              unawaited(
                _openSearchResult(result).whenComplete(() {
                  if (!mounted) return;
                  _setSearchDropdownTapInProgress(false);
                  _searchFocus.unfocus();
                  _scheduleSuggestionOverlaySync();
                }),
              );
            }
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _searchResultStudentName(result),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: fabStyle.text,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: fabStyle.subText,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              _actionLabel(result),
              style: TextStyle(
                color: canOpen ? _rsAccent : fabStyle.subText,
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSuggestionDropdown() {
    if (_searchSuggestBusy) {
      return Container(
        height: 72,
        alignment: Alignment.center,
        child: const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if ((_searchSuggestError ?? '').trim().isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Text(
          _searchSuggestError!.trim(),
          style: const TextStyle(
            color: Color(0xFFE8A3A3),
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            height: 1.35,
          ),
        ),
      );
    }
    if (_searchSuggestions.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Text(
          '미완료 과제 추천이 없습니다.',
          style: TextStyle(
            color: _rsTextSub,
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 250),
      child: ListView.separated(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: _searchSuggestions.length,
        separatorBuilder: (_, __) => const Divider(
          height: 1,
          color: _rsBorder,
          thickness: 0.8,
        ),
        itemBuilder: (context, index) =>
            _buildSuggestionDropdownItem(_searchSuggestions[index]),
      ),
    );
  }

  Widget _buildSearchHeader() {
    final fabStyle = _rightSheetFabColors(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: _topBarTopInset),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 40,
              height: _searchFieldHeight,
              child: IconButton(
                tooltip: '닫기',
                onPressed: widget.onClose,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(),
                icon: const Icon(Icons.chevron_right, size: 24),
                color: fabStyle.subText,
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Container(
                key: _searchHeaderFieldKey,
                height: _searchFieldHeight,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: fabStyle.field,
                  borderRadius: BorderRadius.circular(
                    FabTabBarTokens.fabMenuPillRadius,
                  ),
                  border: Border.all(color: fabStyle.border),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.search_rounded,
                      size: 18,
                      color: fabStyle.subText,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _searchCtrl,
                        focusNode: _searchFocus,
                        onChanged: (value) {
                          if (value.trim().isEmpty) {
                            if (!mounted) return;
                            setState(() {
                              _searchResults =
                                  const <RightSheetGradingSearchResult>[];
                              _searchError = null;
                              _searchBusy = false;
                            });
                          }
                          _scheduleSuggestionSearch(value);
                        },
                        style: TextStyle(
                          color: fabStyle.text,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) {
                          _searchFocus.unfocus();
                          unawaited(_submitSearch());
                        },
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: '과제번호(뒷4자리)/이름/그룹 검색',
                          hintStyle: TextStyle(
                            color: fabStyle.subText.withValues(alpha: 0.82),
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    if (_searchCtrl.text.trim().isNotEmpty)
                      InkWell(
                        borderRadius: BorderRadius.circular(999),
                        onTap: () {
                          _searchFocus.unfocus();
                          _searchSuggestDebounce?.cancel();
                          _searchSuggestRequestSeq += 1;
                          setState(() {
                            _searchCtrl.clear();
                            _searchSuggestions =
                                const <RightSheetGradingSearchResult>[];
                            _searchSuggestError = null;
                            _searchSuggestBusy = false;
                            _searchResults =
                                const <RightSheetGradingSearchResult>[];
                            _searchError = null;
                            _searchBusy = false;
                          });
                          _scheduleSuggestionOverlaySync();
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            Icons.close_rounded,
                            size: 16,
                            color: fabStyle.subText,
                          ),
                        ),
                      ),
                    if (_recentSearches.isNotEmpty) ...[
                      const SizedBox(width: 4),
                      InkWell(
                        borderRadius: BorderRadius.circular(999),
                        onTap: () => unawaited(_clearRecentSearches()),
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(
                            Icons.delete_outline_rounded,
                            size: 18,
                            color: Color(0xFFE06969),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
        if (_recentSearches.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (int i = 0; i < _recentSearches.length; i++)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: fabStyle.panel,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: fabStyle.border),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      InkWell(
                        onTap: () =>
                            unawaited(_openRecentSearch(_recentSearches[i])),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 320),
                          child: Text(
                            _recentSearchChipLabel(_recentSearches[i]),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: fabStyle.text,
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      InkWell(
                        onTap: () => unawaited(_removeRecentAt(i)),
                        child: Icon(
                          Icons.close_rounded,
                          size: 16,
                          color: fabStyle.subText,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  void _syncGradingSearchOverlayHeight() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _gradingSearchOverlayKey.currentContext?.findRenderObject()
          as RenderBox?;
      if (box == null || !box.hasSize) return;
      final next = box.size.height;
      if (next <= 0 || (next - _gradingSearchOverlayHeight).abs() < 0.5) {
        return;
      }
      setState(() => _gradingSearchOverlayHeight = next);
    });
  }

  Widget _buildGradingSearchOverlay() {
    final fabStyle = _rightSheetFabColors(context);
    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        _syncGradingSearchOverlayHeight();
        return false;
      },
      child: SizeChangedLayoutNotifier(
        child: DecoratedBox(
          key: _gradingSearchOverlayKey,
          decoration: BoxDecoration(color: fabStyle.surface),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildSearchHeader(),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  String _actionLabel(RightSheetGradingSearchResult result) {
    if (result.isTestHomework) {
      return result.isSubmitted ? '채점 진입' : '제출 후 채점';
    }
    if (result.hasTextbookLink) return '답지 바로가기';
    return '교재 없음';
  }

  Widget _buildSearchResultTile(
    RightSheetGradingSearchResult result, {
    String? actionOverride,
  }) {
    final fabStyle = _rightSheetFabColors(context);
    final code = result.assignmentCode.trim().isEmpty
        ? '-'
        : result.assignmentCode.trim();
    final canOpen = result.isTestHomework || result.hasTextbookLink;
    final openAction = canOpen && !_searchOpenBusy
        ? () => unawaited(_openSearchResult(result))
        : null;
    final title = _searchResultTitle(result);
    final subtitleParts = <String>[
      if (code != '-') code,
      if (result.isTestHomework) (result.isSubmitted ? '테스트 제출됨' : '테스트 미제출'),
    ];
    return InkWell(
      onTap: openAction,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 9, 8, 9),
        decoration: BoxDecoration(
          color: fabStyle.field,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: fabStyle.border),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _searchResultStudentName(result),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: fabStyle.text,
                            fontSize: 13,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            color: fabStyle.subText,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (subtitleParts.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitleParts.join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: fabStyle.subText,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 34,
              child: OutlinedButton(
                onPressed: openAction,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  minimumSize: const Size(70, 34),
                  side: BorderSide(
                    color: canOpen ? _rsAccent : fabStyle.border,
                  ),
                  foregroundColor: canOpen ? _rsAccent : fabStyle.subText,
                  backgroundColor: canOpen
                      ? _rsAccent.withValues(alpha: 0.14)
                      : fabStyle.panel,
                ),
                child: Text(
                  actionOverride ?? _actionLabel(result),
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchResultSection() {
    final fabStyle = _rightSheetFabColors(context);
    final query = _searchCtrl.text.trim();
    if (query.isEmpty) {
      return const SizedBox.shrink();
    }
    if (_searchBusy) {
      return Container(
        height: 96,
        decoration: BoxDecoration(
          color: fabStyle.panel,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: fabStyle.border),
        ),
        alignment: Alignment.center,
        child: const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if ((_searchError ?? '').trim().isNotEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: fabStyle.panel,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF4A2A2A)),
        ),
        child: Text(
          _searchError!.trim(),
          style: const TextStyle(
            color: Color(0xFFE8A3A3),
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            height: 1.35,
          ),
        ),
      );
    }
    if (_searchResults.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: fabStyle.panel,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: fabStyle.border),
        ),
        child: Text(
          '검색 결과가 없습니다.',
          style: TextStyle(
            color: fabStyle.subText,
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }

    return Container(
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: BoxDecoration(
        color: fabStyle.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: fabStyle.border),
      ),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        itemCount: _searchResults.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) =>
            _buildSearchResultTile(_searchResults[index]),
      ),
    );
  }

  Widget _buildSessionHeader(RightSideSheetTestGradingSession session) {
    final fabStyle = _rightSheetFabColors(context);
    final studentName =
        session.studentName.trim().isEmpty ? '학생' : session.studentName.trim();
    final groupHomeworkTitle = session.groupHomeworkTitle.trim().isEmpty
        ? (session.title.trim().isEmpty ? '그룹 과제' : session.title.trim())
        : session.groupHomeworkTitle.trim();
    final assignmentCode = session.assignmentCode.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  studentName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fabStyle.subText,
                    fontWeight: FontWeight.w800,
                    fontSize: 25,
                  ),
                ),
              ),
            ),
            if (assignmentCode.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text(
                assignmentCode,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: fabStyle.subText,
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  groupHomeworkTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fabStyle.text,
                    fontWeight: FontWeight.w900,
                    fontSize: 20,
                  ),
                ),
              ),
            ),
            if (_baselineStates.isNotEmpty) ...[
              const SizedBox(width: 10),
              InkWell(
                borderRadius: BorderRadius.circular(9),
                onTap: () {
                  setState(() {
                    _wrongOnly = !_wrongOnly;
                  });
                },
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 22,
                        height: 22,
                        child: IgnorePointer(
                          child: Checkbox(
                            value: _wrongOnly,
                            onChanged: (_) {},
                            activeColor: _rsAccent,
                            checkColor: Colors.white,
                            side: BorderSide(color: fabStyle.subText),
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '틀린것만 보기',
                        style: TextStyle(
                          color: fabStyle.subText,
                          fontWeight: FontWeight.w800,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  bool _isSessionAnswerWebUrl(String raw) {
    final lower = raw.trim().toLowerCase();
    return lower.startsWith('http://') || lower.startsWith('https://');
  }

  String _sessionTextbookStorageKey(String rawPath) {
    final trimmed = rawPath.trim();
    if (trimmed.isEmpty || _isSessionAnswerWebUrl(trimmed)) return '';
    final withoutScheme =
        trimmed.toLowerCase().startsWith('storage://textbook/')
            ? trimmed.substring('storage://textbook/'.length)
            : trimmed;
    final key = withoutScheme.split('?').first.trim();
    if (!RegExp(r'^academies/.+\.pdf$', caseSensitive: false).hasMatch(key)) {
      return '';
    }
    return key;
  }

  Future<String> _sessionSignedTextbookPdfUrl(String rawPath) async {
    final key = _sessionTextbookStorageKey(rawPath);
    if (key.isEmpty) return '';
    try {
      return await Supabase.instance.client.storage
          .from('textbooks')
          .createSignedUrl(key, 60 * 60);
    } catch (_) {
      return '';
    }
  }

  String _sessionLocalFilePath(String rawPath) {
    final trimmed = rawPath.trim();
    if (trimmed.isEmpty || _isSessionAnswerWebUrl(trimmed)) return '';
    if (_sessionTextbookStorageKey(trimmed).isNotEmpty) return '';
    if (trimmed.toLowerCase().startsWith('file://')) {
      try {
        return Uri.parse(trimmed).toFilePath(windows: Platform.isWindows);
      } catch (_) {
        return trimmed.replaceFirst(RegExp(r'^file:///?'), '');
      }
    }
    return trimmed;
  }

  TextbookPdfRef? _textbookPdfRefFromStoragePath(
    String rawPath, {
    required String kind,
  }) {
    final key = _sessionTextbookStorageKey(rawPath);
    if (key.isEmpty) return null;
    final match = RegExp(
      r'^academies/([^/]+)/files/([^/]+)/(.+)/(body|ans|sol)\.pdf$',
      caseSensitive: false,
    ).firstMatch(key);
    if (match == null) return null;
    final fileKind = (match.group(4) ?? kind).toLowerCase();
    return TextbookPdfRef(
      academyId: match.group(1),
      fileId: match.group(2),
      gradeLabel: match.group(3),
      kind: fileKind,
      storageKey: key,
    );
  }

  Future<String> _resolveSessionPdfViewerPath(
    String rawPath, {
    required String kind,
  }) async {
    final trimmed = rawPath.trim();
    if (trimmed.isEmpty) return '';
    if (_isSessionAnswerWebUrl(trimmed)) return trimmed;

    final localCandidate = _sessionLocalFilePath(trimmed);
    if (localCandidate.isNotEmpty &&
        localCandidate.toLowerCase().endsWith('.pdf') &&
        await File(localCandidate).exists()) {
      return localCandidate;
    }

    final ref = _textbookPdfRefFromStoragePath(trimmed, kind: kind);
    if (ref != null) {
      try {
        final source = await TextbookPdfService.instance.resolve(ref);
        final resolved = (source.localPath ?? '').trim().isNotEmpty
            ? source.localPath!.trim()
            : (source.url ?? '').trim();
        if (resolved.isNotEmpty) return resolved;
      } catch (e) {
        debugPrint('[RIGHT_SHEET_PDF] textbook cache resolve failed: $e');
      }
      final signed = await _sessionSignedTextbookPdfUrl(trimmed);
      if (signed.trim().isNotEmpty) return signed.trim();
    }

    return '';
  }

  BuildContext get _navigatorContext => widget.dialogContext ?? context;

  Future<T?> _showTopOverlayDialog<T>({
    required Widget Function(
            BuildContext context, void Function([T? result]) close)
        builder,
    bool barrierDismissible = true,
  }) async {
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) {
      return showDialog<T>(
        context: _navigatorContext,
        useRootNavigator: true,
        barrierDismissible: barrierDismissible,
        builder: (dialogContext) => builder(
          dialogContext,
          ([result]) =>
              Navigator.of(dialogContext, rootNavigator: true).pop(result),
        ),
      );
    }

    final completer = Completer<T?>();
    late OverlayEntry entry;
    void close([T? result]) {
      if (completer.isCompleted) return;
      entry.remove();
      completer.complete(result);
    }

    entry = OverlayEntry(
      builder: (overlayContext) {
        return Material(
          type: MaterialType.transparency,
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  onTap: barrierDismissible ? () => close() : null,
                  behavior: HitTestBehavior.opaque,
                  child: Container(color: Colors.black.withValues(alpha: 0.54)),
                ),
              ),
              Center(child: builder(overlayContext, close)),
            ],
          ),
        );
      },
    );
    overlay.insert(entry);
    return completer.future;
  }

  Future<void> _openSessionAnswerSheet(
    RightSideSheetTestGradingSession session, {
    bool initialShowSolution = false,
    int focusPageNumber = 0,
    List<int> focusRect1k = const <int>[],
    String answerPathRawOverride = '',
    String solutionPathRawOverride = '',
    bool preferSolutionRawAsBase = false,
  }) async {
    if (_answerPdfOpening) return;
    final answerRaw = answerPathRawOverride.trim().isNotEmpty
        ? answerPathRawOverride.trim()
        : session.answerPathRaw.trim();
    final solutionRaw = solutionPathRawOverride.trim().isNotEmpty
        ? solutionPathRawOverride.trim()
        : session.solutionPathRaw.trim();
    final raw = preferSolutionRawAsBase && solutionRaw.isNotEmpty
        ? solutionRaw
        : (answerRaw.isNotEmpty ? answerRaw : solutionRaw);
    if (raw.isEmpty) return;
    final cacheKey = session.answerViewerCacheKey.trim().isEmpty
        ? 'right_sheet_answer:${session.sessionId}'
        : session.answerViewerCacheKey.trim();
    setState(() => _answerPdfOpening = true);
    try {
      final baseIsSolution = preferSolutionRawAsBase && solutionRaw.isNotEmpty;

      // For solution jumps to a specific page, fetch a tiny single-page PDF
      // (lossless, original resolution) instead of opening the huge full
      // solution PDF (143~318MB). Falls back to the full PDF on any failure.
      String solutionPageFile = '';
      int effectiveFocusPage = focusPageNumber;
      if (focusPageNumber > 0 && solutionRaw.isNotEmpty) {
        final solRef = _textbookPdfRefFromStoragePath(solutionRaw, kind: 'sol');
        if (solRef != null) {
          try {
            final page = await TextbookPdfService.instance
                .resolvePage(solRef, focusPageNumber);
            if (page != null && page.localPath.trim().isNotEmpty) {
              solutionPageFile = page.localPath.trim();
              effectiveFocusPage = page.localPage;
            }
          } catch (e) {
            debugPrint('[RIGHT_SHEET_PDF] solution page extract failed: $e');
          }
        }
      }

      final String answerPath;
      if (baseIsSolution && solutionPageFile.isNotEmpty) {
        // Base document is the solution itself; serve only the focused page.
        answerPath = solutionPageFile;
      } else {
        answerPath = await _resolveSessionPdfViewerPath(
          raw,
          kind: baseIsSolution ? 'sol' : 'ans',
        );
      }
      if (answerPath.trim().isEmpty) return;
      if (!_isSessionAnswerWebUrl(answerPath)) {
        final file = File(answerPath);
        if (!answerPath.toLowerCase().endsWith('.pdf') ||
            !await file.exists()) {
          if (!mounted) return;
          ScaffoldMessenger.of(_navigatorContext).showSnackBar(
            const SnackBar(content: Text('답지 PDF 파일을 찾을 수 없습니다.')),
          );
          return;
        }
      }

      final String solutionPath;
      if (baseIsSolution && solutionPageFile.isNotEmpty) {
        // The focused page is already the base document.
        solutionPath = '';
      } else if (solutionPageFile.isNotEmpty) {
        solutionPath = solutionPageFile;
      } else if (solutionRaw.isEmpty) {
        solutionPath = '';
      } else {
        solutionPath =
            await _resolveSessionPdfViewerPath(solutionRaw, kind: 'sol');
      }
      if (!mounted) return;

      // When the focused page became the base document, it is shown directly
      // (no solution toggle needed).
      final focusTargetsBase = baseIsSolution && solutionPageFile.isNotEmpty;
      final shouldShowSolution = focusTargetsBase
          ? false
          : initialShowSolution && solutionPath.trim().isNotEmpty;
      final finalFocusPage =
          solutionPageFile.isNotEmpty ? effectiveFocusPage : focusPageNumber;
      final focusRequestId = finalFocusPage > 0 ? ++_pdfFocusRequestSeq : 0;
      rightSideSheetPdfPanelSession.value = RightSideSheetPdfPanelSession(
        sessionId: session.sessionId,
        title: session.title.trim().isEmpty ? '답지 확인' : session.title.trim(),
        answerPath: answerPath.trim(),
        solutionPath: solutionPath.trim(),
        cacheKey: cacheKey,
        showSolution: shouldShowSolution,
        focusPageNumber: finalFocusPage > 0 ? finalFocusPage : 0,
        focusRequestId: focusRequestId,
        focusRect1k: finalFocusPage > 0 ? focusRect1k : const <int>[],
        overlayEntries: session.overlayEntries
            .map(
              (entry) => <String, String>{
                'title': '${entry['title'] ?? ''}',
                'page': '${entry['page'] ?? ''}',
                'memo': '${entry['memo'] ?? ''}',
              },
            )
            .toList(growable: false),
      );
      RightSheetAnswerPreloadService.instance.putPdfLinks(
        cacheKey: cacheKey,
        answerPath: answerPath,
        solutionPath: solutionPath,
      );
    } finally {
      if (mounted) {
        setState(() => _answerPdfOpening = false);
      }
    }
  }

  ({int pageNumber, List<int> rect1k}) _firstAnswerPdfFocus(
    RightSideSheetTestGradingSession session,
  ) {
    _RightSheetGradingCellVm? firstCell;
    var firstPageNumber = 0;
    for (final page in _visiblePages()) {
      for (final cell in page.cells) {
        final answerPage = cell.answerPageNumber;
        if (answerPage == null || answerPage <= 0) continue;
        if (firstCell == null ||
            page.pageNumber < firstPageNumber ||
            (page.pageNumber == firstPageNumber &&
                cell.questionIndex < firstCell.questionIndex)) {
          firstCell = cell;
          firstPageNumber = page.pageNumber;
        }
      }
    }
    if (firstCell != null) {
      return (
        pageNumber: firstCell.answerPageNumber ?? 0,
        rect1k: firstCell.answerRect1k,
      );
    }

    int parsePositiveInt(dynamic raw) {
      final value = raw is int ? raw : int.tryParse('$raw');
      return value != null && value > 0 ? value : 0;
    }

    List<int> parseRect1k(dynamic raw) {
      final source = raw is String
          ? (() {
              try {
                return jsonDecode(raw);
              } catch (_) {
                return raw
                    .split(RegExp(r'[, ]+'))
                    .where((part) => part.trim().isNotEmpty)
                    .toList();
              }
            })()
          : raw;
      if (source is! List) return const <int>[];
      final values = source
          .map((entry) => entry is int ? entry : int.tryParse('$entry'))
          .whereType<int>()
          .toList(growable: false);
      return values.length >= 4 ? values.take(4).toList() : const <int>[];
    }

    var fallbackPage = 0;
    var fallbackIndex = 1 << 30;
    var fallbackRect = const <int>[];
    for (final rawPage in session.gradingPages) {
      final rawCells = rawPage['cells'];
      if (rawCells is! List) continue;
      for (final rawCell in rawCells) {
        if (rawCell is! Map) continue;
        final answerPage = parsePositiveInt(
          rawCell['answerPageNumber'] ??
              rawCell['answer_page_number'] ??
              rawCell['answerRawPage'] ??
              rawCell['answer_raw_page'] ??
              rawCell['answerDisplayPage'] ??
              rawCell['answer_display_page'],
        );
        if (answerPage <= 0) continue;
        final questionIndex = parsePositiveInt(
          rawCell['questionIndex'] ?? rawCell['question_index'],
        );
        if (fallbackPage == 0 || questionIndex < fallbackIndex) {
          fallbackPage = answerPage;
          fallbackIndex = questionIndex <= 0 ? fallbackIndex : questionIndex;
          fallbackRect = parseRect1k(
            rawCell['answerRect1k'] ??
                rawCell['answer_rect_1k'] ??
                rawCell['answerBbox1k'] ??
                rawCell['answer_bbox_1k'],
          );
        }
      }
    }
    return (pageNumber: fallbackPage, rect1k: fallbackRect);
  }

  Future<void> _openCellSolution(
    _RightSheetGradingCellVm cell, {
    required int pageNumber,
  }) async {
    if (_answerPdfOpening || _openingSolutionCellKey.isNotEmpty) return;
    final session = widget.session;
    if (session == null) return;
    final hasSolutionSource = cell.solutionPathRaw.trim().isNotEmpty ||
        session.solutionPathRaw.trim().isNotEmpty;
    final hasSolutionTarget = cell.solutionPathRaw.trim().isNotEmpty ||
        cell.solutionPageNumber != null ||
        cell.solutionRect1k.length >= 4;
    if (!hasSolutionSource || !hasSolutionTarget) {
      if (!mounted) return;
      await _showNoLinkedSolutionDialog(cell);
      return;
    }
    if (mounted) {
      setState(() => _openingSolutionCellKey = cell.key);
    }
    try {
      await _openSessionAnswerSheet(
        session,
        initialShowSolution: true,
        focusPageNumber: cell.solutionPageNumber ?? pageNumber,
        focusRect1k: cell.solutionRect1k.length >= 4
            ? cell.solutionRect1k
            : cell.focusRect1k,
        answerPathRawOverride: cell.answerPathRaw,
        solutionPathRawOverride: cell.solutionPathRaw,
        preferSolutionRawAsBase: cell.answerPathRaw.trim().isEmpty &&
            cell.solutionPathRaw.isNotEmpty,
      );
    } finally {
      if (mounted && _openingSolutionCellKey == cell.key) {
        setState(() => _openingSolutionCellKey = '');
      }
    }
  }

  Future<void> _showNoLinkedSolutionDialog(
    _RightSheetGradingCellVm cell,
  ) async {
    await _showTopOverlayDialog<void>(
      builder: (dialogContext, closeDialog) {
        return AlertDialog(
          backgroundColor: context.yggSurfaceBase,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: _rsBorder),
          ),
          title: Text(
            '${cell.displayQuestionLabel}번 해설',
            style: const TextStyle(
              color: _rsText,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          content: const Text(
            '이 문항에 연결된 해설이 없습니다.',
            style: TextStyle(color: _rsTextSub, fontSize: 14, height: 1.4),
          ),
          actions: [
            FilledButton(
              onPressed: () => closeDialog(),
              style: FilledButton.styleFrom(
                backgroundColor: _rsAccent,
                foregroundColor: Colors.white,
              ),
              child: const Text('확인'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openQuestionSourceInfoDialog(
    _RightSheetGradingCellVm cell,
  ) async {
    if (cell.sourceInfo.isEmpty) {
      ScaffoldMessenger.of(_navigatorContext).showSnackBar(
        const SnackBar(content: Text('표시할 문항 출처 정보가 없습니다.')),
      );
      return;
    }
    await _showTopOverlayDialog<void>(
      builder: (dialogContext, closeDialog) {
        return _QuestionSourceInfoDialog(
          questionLabel: cell.displayQuestionLabel,
          sourceInfo: cell.sourceInfo,
          onClose: closeDialog,
        );
      },
    );
  }

  ({String studentId, String homeworkItemId}) _reportContextIdsFromSession() {
    final sessionId =
        (widget.session?.sessionId ?? '').replaceFirst('preload:', '');
    final match =
        RegExp(r'student:([^|]+)\|[^:]+:([^|]+)').firstMatch(sessionId);
    return (
      studentId: (match?.group(1) ?? '').trim(),
      homeworkItemId: (match?.group(2) ?? '').trim(),
    );
  }

  Future<void> _openQuestionIssueReportDialog(
    _RightSheetGradingCellVm cell,
  ) async {
    if (cell.answerSourceKind != 'pb_question' ||
        cell.answerSourceId.trim().isEmpty) {
      ScaffoldMessenger.of(_navigatorContext).showSnackBar(
        const SnackBar(content: Text('문제은행 문항만 오류 신고를 남길 수 있습니다.')),
      );
      return;
    }
    final academyId = await _resolveActiveAcademyId();
    if (!mounted) return;
    if (academyId.isEmpty) {
      ScaffoldMessenger.of(_navigatorContext).showSnackBar(
        const SnackBar(content: Text('학원 정보를 찾지 못해 오류 신고를 저장할 수 없습니다.')),
      );
      return;
    }

    final selected = <String>{};
    final noteCtrl = TextEditingController();
    var submitting = false;
    await _showTopOverlayDialog<void>(
      builder: (dialogContext, closeDialog) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> submit() async {
              if (selected.isEmpty || submitting) return;
              setDialogState(() => submitting = true);
              try {
                final contextIds = _reportContextIdsFromSession();
                await ProblemQuestionIssueReportService.instance.createReport(
                  academyId: academyId,
                  questionId: cell.answerSourceId,
                  issueTypes: selected.toList(growable: false),
                  homeworkItemId: contextIds.homeworkItemId,
                  studentId: contextIds.studentId,
                  note: noteCtrl.text,
                );
                if (!context.mounted) return;
                closeDialog();
                if (!mounted) return;
                ScaffoldMessenger.of(_navigatorContext).showSnackBar(
                  SnackBar(
                    content:
                        Text('${cell.displayQuestionLabel}번 오류 신고를 저장했습니다.'),
                  ),
                );
              } catch (_) {
                if (!context.mounted) return;
                setDialogState(() => submitting = false);
                ScaffoldMessenger.of(_navigatorContext).showSnackBar(
                  const SnackBar(content: Text('오류 신고 저장에 실패했습니다.')),
                );
              }
            }

            return AlertDialog(
              backgroundColor: context.yggSurfaceBase,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: _rsBorder),
              ),
              title: Text(
                '${cell.displayQuestionLabel}번 오류 리포트',
                style: const TextStyle(
                  color: _rsText,
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              content: SizedBox(
                width: 520,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '해당 문항에서 발견한 오류를 선택해 주세요.',
                      style: TextStyle(color: _rsTextSub, fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final type in kProblemQuestionIssueTypes)
                          _QuestionIssueTypeChip(
                            label: type.label,
                            selected: selected.contains(type.key),
                            enabled: !submitting,
                            onSelected: (value) {
                              setDialogState(() {
                                if (value) {
                                  selected.add(type.key);
                                } else {
                                  selected.remove(type.key);
                                }
                              });
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: noteCtrl,
                      enabled: !submitting,
                      minLines: 2,
                      maxLines: 4,
                      style: const TextStyle(color: _rsText),
                      decoration: const InputDecoration(
                        hintText: '추가 설명이 있으면 적어주세요.',
                        hintStyle: TextStyle(color: _rsTextSub),
                        filled: true,
                        fillColor: _rsPanelBg,
                        enabledBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: _rsBorder),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: _rsAccent),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: submitting ? null : () => closeDialog(),
                  style: TextButton.styleFrom(foregroundColor: _rsTextSub),
                  child: const Text('취소'),
                ),
                FilledButton(
                  onPressed: selected.isEmpty || submitting
                      ? null
                      : () => unawaited(submit()),
                  style: FilledButton.styleFrom(
                    backgroundColor: _rsAccent,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: _rsFieldBg,
                    disabledForegroundColor: _rsTextSub,
                  ),
                  child: submitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('신고'),
                ),
              ],
            );
          },
        );
      },
    );
    noteCtrl.dispose();
  }

  ({double correctScore, double totalScore}) _computeScoreResult(
    RightSideSheetTestGradingSession session,
  ) {
    final scoreMap = session.scoreByQuestionKey;
    final hasScoreData = scoreMap.isNotEmpty;
    var correctScore = 0.0;
    var totalScore = 0.0;
    final seenKeys = <String>{};
    for (final rawPage in session.gradingPages) {
      final rawCells = rawPage['cells'];
      if (rawCells is! List) continue;
      for (final rawCell in rawCells) {
        if (rawCell is! Map) continue;
        final key = '${rawCell['key'] ?? ''}'.trim();
        if (key.isEmpty || !seenKeys.add(key)) continue;
        final pointValue = hasScoreData ? (scoreMap[key] ?? 1.0) : 1.0;
        totalScore += pointValue;
        final state = _normalizeState(_gradingStates[key]);
        if (state == 'correct') {
          correctScore += pointValue;
        }
      }
    }
    return (correctScore: correctScore, totalScore: totalScore);
  }

  String _formatScoreDisplay(double v) {
    final rounded = v.roundToDouble();
    if ((v - rounded).abs() < 0.0001) return rounded.toStringAsFixed(0);
    return v.toStringAsFixed(1);
  }

  Widget _buildScoreCalculator(RightSideSheetTestGradingSession session) {
    final result = _computeScoreResult(session);
    final hasScoreData = session.scoreByQuestionKey.isNotEmpty;
    final label = hasScoreData ? '총점' : '맞은 개수';

    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        '$label  ${_formatScoreDisplay(result.correctScore)} / ${_formatScoreDisplay(result.totalScore)}',
        textAlign: TextAlign.left,
        style: const TextStyle(
          color: _rsText,
          fontWeight: FontWeight.w900,
          fontSize: 18.5,
          letterSpacing: 0.2,
          height: 1.0,
        ),
      ),
    );
  }

  ({
    Color border,
    Color background,
    Color text,
    String label,
  }) _resolveAnswerRowStyle(String state) {
    switch (_normalizeState(state)) {
      case 'wrong':
        return (
          border: const Color(0xFFE54848),
          background: const Color(0xFF151C21),
          text: const Color(0xFFFFD7DE),
          label: '오답',
        );
      case 'unsolved':
        return (
          border: const Color(0xFF4F626B),
          background: const Color(0xFF151C21),
          text: const Color(0xFFA9BAC4),
          label: '미풀이',
        );
      default:
        return (
          border: const Color(0xFF223131),
          background: const Color(0xFF151C21),
          text: const Color(0xFFEAF2F7),
          label: '정답',
        );
    }
  }

  bool _isObjectiveAnswer({
    required String answer,
    required String answerMode,
  }) {
    final mode = answerMode.trim().toLowerCase();
    if (mode == 'objective' || mode == 'choice' || mode == 'multiple_choice') {
      return true;
    }
    final compact = answer.trim().replaceAll(RegExp(r'[\s,;/]+'), '');
    return compact.isNotEmpty &&
        RegExp(r'^[①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳]+$').hasMatch(compact);
  }

  String _normalizeAnswerRenderKind(String raw) {
    final kind = raw.trim().toLowerCase();
    if (kind == 'essay' || kind.contains('서술')) return 'essay';
    if (kind == 'subjective' || kind.contains('주관')) return 'subjective';
    return 'subjective';
  }

  String _answerRenderKindForRawCell(Map rawCell) {
    final explicit =
        '${rawCell['answerRenderKind'] ?? rawCell['answer_render_kind'] ?? rawCell['answerRenderPolicy'] ?? rawCell['answer_render_policy'] ?? rawCell['answerKind'] ?? rawCell['answer_kind'] ?? ''}'
            .trim();
    if (explicit.isNotEmpty) return _normalizeAnswerRenderKind(explicit);
    return _normalizeAnswerRenderKind(
      '${rawCell['answerMode'] ?? rawCell['mode'] ?? ''}',
    );
  }

  int? _circledObjectiveNumber(String value) {
    switch (value.trim()) {
      case '①':
        return 1;
      case '②':
        return 2;
      case '③':
        return 3;
      case '④':
        return 4;
      case '⑤':
        return 5;
      case '⑥':
        return 6;
      case '⑦':
        return 7;
      case '⑧':
        return 8;
      case '⑨':
        return 9;
      case '⑩':
        return 10;
      case '⑪':
        return 11;
      case '⑫':
        return 12;
      case '⑬':
        return 13;
      case '⑭':
        return 14;
      case '⑮':
        return 15;
      case '⑯':
        return 16;
      case '⑰':
        return 17;
      case '⑱':
        return 18;
      case '⑲':
        return 19;
      case '⑳':
        return 20;
      default:
        return null;
    }
  }

  List<int> _objectiveAnswerNumbers(String answer) {
    final numbers = <int>[];
    for (final rune in answer.runes) {
      final parsed = _circledObjectiveNumber(String.fromCharCode(rune));
      if (parsed != null) numbers.add(parsed);
    }
    return numbers;
  }

  Widget _buildObjectiveAnswerFlutter(_RightSheetGradingCellVm cell) {
    final answer = cell.answer.trim().isEmpty ? '-' : cell.answer.trim();
    final numbers = _objectiveAnswerNumbers(answer);
    if (numbers.isNotEmpty) {
      final circledAnswers = answer.runes
          .map(String.fromCharCode)
          .where((ch) => _circledObjectiveNumber(ch) != null)
          .toList(growable: false);
      return Padding(
        padding: const EdgeInsets.only(left: 16),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Wrap(
            alignment: WrapAlignment.start,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 10,
            runSpacing: 6,
            children: [
              for (int i = 0; i < circledAnswers.length; i++)
                Text(
                  i == circledAnswers.length - 1
                      ? circledAnswers[i]
                      : '${circledAnswers[i]},',
                  textAlign: TextAlign.left,
                  style: const TextStyle(
                    color: _rsText,
                    fontFamily: 'ChosunNm',
                    fontWeight: FontWeight.w400,
                    fontSize: 39.5,
                    height: 1.0,
                  ),
                ),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(left: 16),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          answer,
          textAlign: TextAlign.left,
          style: const TextStyle(
            color: _rsText,
            fontWeight: FontWeight.w900,
            fontSize: 33.75,
            height: 1.15,
          ),
        ),
      ),
    );
  }

  double _answerImageNaturalDisplayHeight({
    required double rawHeight,
    required double pixelRatio,
  }) {
    if (!rawHeight.isFinite || rawHeight <= 0) return 28.0;
    final safePixelRatio = pixelRatio.isFinite && pixelRatio > 0
        ? pixelRatio
        : _answerRenderDefaultPixelRatio;
    final naturalHeight = rawHeight / safePixelRatio;
    if (!naturalHeight.isFinite || naturalHeight <= 0) {
      return _answerSlotHeight;
    }
    return naturalHeight;
  }

  List<({String label, String value})> _splitSetAnswerParts(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return const [];
    final matches = RegExp(r'(?<![\d.])[(（]\s*(\d{1,2})\s*[)）]')
        .allMatches(text)
        .toList(growable: false);
    if (matches.length < 2) return const [];
    return [
      for (var i = 0; i < matches.length; i += 1)
        (
          label: '(${matches[i].group(1) ?? (i + 1).toString()})',
          value: text
              .substring(
                matches[i].end,
                i + 1 < matches.length ? matches[i + 1].start : text.length,
              )
              .trim(),
        ),
    ].where((part) => part.value.isNotEmpty).toList(growable: false);
  }

  int _estimatedInlineAnswerLineCount(_RightSheetGradingCellVm cell) {
    final answer = cell.answer.trim();
    if (answer.isEmpty) return 1;
    final setParts = _splitSetAnswerParts(answer);
    if (setParts.isNotEmpty) {
      var lines = 0;
      for (final part in setParts) {
        final plain = part.value
            .replaceAll(
                RegExp(r'\\(?:dfrac|tfrac|frac)\s*\{([^{}]+)\}\s*\{([^{}]+)\}'),
                r'$1/$2')
            .replaceAll(RegExp(r'\\[a-zA-Z]+'), ' ')
            .replaceAll(RegExp(r'[{}$\\^_]'), '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        final extra = (plain.length / 28).ceil();
        lines += math.max(1, extra);
      }
      return lines;
    }
    final normalized = _normalizeAnswerForOverflowDisplay(answer);
    final explicitLines = '\n'.allMatches(normalized).length + 1;
    final plainLength = normalized
        .replaceAll(
            RegExp(r'\\(?:dfrac|tfrac|frac)\s*\{([^{}]+)\}\s*\{([^{}]+)\}'),
            r'$1/$2')
        .replaceAll(RegExp(r'\\[a-zA-Z]+'), ' ')
        .replaceAll(RegExp(r'[{}$\\^_]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .length;
    final estimatedByLength = (plainLength / 34).ceil();
    final tallMathExtra =
        RegExp(r'\\(?:dfrac|tfrac|frac)\b|\\left|\\right').hasMatch(answer)
            ? 1
            : 0;
    return math.max(explicitLines, estimatedByLength) + tallMathExtra;
  }

  double _inlineAnswerSlotHeight(_RightSheetGradingCellVm cell) {
    final lineCount = _estimatedInlineAnswerLineCount(cell);
    final height = (lineCount * _inlineAnswerLineHeight) + 6.0;
    return math.max(_answerSlotHeight, height);
  }

  double _answerSlotHeightForCell(_RightSheetGradingCellVm cell) {
    if (_isObjectiveAnswer(
      answer: cell.answer,
      answerMode: cell.answerMode,
    )) {
      return _answerSlotHeight;
    }
    if (_isRawAnswerImageCell(cell)) {
      final rawHeight = (cell.answerImageHeight ?? 0).toDouble();
      final pixelRatio = cell.answerImagePixelRatio != null &&
              cell.answerImagePixelRatio!.isFinite &&
              cell.answerImagePixelRatio! > 0
          ? cell.answerImagePixelRatio!
          : 1.0;
      final displayHeight = rawHeight > 0 ? rawHeight / pixelRatio : 38.0;
      return math.max(
        _answerSlotHeight,
        displayHeight + _answerImageVerticalPadding,
      );
    }
    final render = _answerRenders[cell.key];
    if (render != null && render.hasImage) {
      if (render.styleVersion.trim() != kUnifiedAnswerRenderStyleVersion) {
        return _answerSlotHeight;
      }
      final rowHeight = render.rowHeightDp;
      final displayHeight = render.displayHeightDp;
      final minimumAssetDrivenHeight =
          displayHeight != null && displayHeight.isFinite && displayHeight > 0
              ? displayHeight + _answerImageVerticalPadding
              : 0.0;
      if (rowHeight != null && rowHeight.isFinite && rowHeight > 0) {
        return math.max(rowHeight, minimumAssetDrivenHeight);
      }
      final pixelRatio = render.pixelRatio <= 0
          ? _answerRenderDefaultPixelRatio
          : render.pixelRatio;
      final fallbackDisplayHeight = render.height > 0
          ? render.height.toDouble() / pixelRatio
          : _answerSlotHeight;
      return math.max(
        _answerSlotHeight,
        fallbackDisplayHeight + _answerImageVerticalPadding,
      );
    }
    return _answerSlotHeight;
  }

  Widget _buildAnswerNetworkImage({
    required String url,
    required double rawWidth,
    required double rawHeight,
    required double pixelRatio,
    required String styleVersion,
    double? displayWidthDp,
    double? displayHeightDp,
    required double slotHeight,
    required BoxConstraints constraints,
    required Widget Function() fallbackBuilder,
    bool alignLeft = true,
    double leftPadding = 0,
  }) {
    final aspect = rawWidth > 0 && rawHeight > 0 ? rawWidth / rawHeight : 3.0;
    final maxWidth =
        constraints.maxWidth.isFinite ? constraints.maxWidth : 220.0;
    final contentMaxWidth = math.max(1.0, maxWidth - leftPadding);
    final displayHeight = displayHeightDp != null &&
            displayHeightDp.isFinite &&
            displayHeightDp > 0
        ? displayHeightDp
        : rawHeight / math.max(1.0, pixelRatio);
    final displayWidth =
        displayWidthDp != null && displayWidthDp.isFinite && displayWidthDp > 0
            ? displayWidthDp
            : displayHeight * aspect;
    final keepReadableWithHorizontalScroll = displayWidth > contentMaxWidth;

    final imageAlignment =
        alignLeft ? Alignment.centerLeft : Alignment.centerRight;
    final image = Image.network(
      url,
      width: displayWidth,
      height: displayHeight,
      fit: BoxFit.contain,
      alignment: imageAlignment,
      filterQuality: FilterQuality.high,
      errorBuilder: (_, __, ___) => fallbackBuilder(),
    );
    final content = keepReadableWithHorizontalScroll
        ? SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: image,
          )
        : image;

    final safeSlotHeight =
        math.max(slotHeight, displayHeight + _answerImageVerticalPadding);
    return SizedBox(
      height: safeSlotHeight,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          leftPadding,
          _answerImageTopPadding,
          0,
          _answerImageBottomPadding,
        ),
        child: Align(
          alignment: imageAlignment,
          child: content,
        ),
      ),
    );
  }

  bool _isRawAnswerImageCell(_RightSheetGradingCellVm cell) {
    return cell.answerAssetKind.trim().toLowerCase() == 'raw_answer_image' &&
        cell.answerImageUrl.trim().isNotEmpty;
  }

  Future<void> _openRawAnswerImageDialog(_RightSheetGradingCellVm cell) async {
    final url = cell.answerImageUrl.trim();
    if (url.isEmpty || !mounted) return;
    await _showTopOverlayDialog<void>(
      builder: (dialogContext, closeDialog) => _RawAnswerImageZoomDialog(
        title: '${cell.displayQuestionLabel}번 이미지 정답',
        url: url,
        onClose: closeDialog,
      ),
    );
  }

  Widget _buildAnswerImageOrFallback(_RightSheetGradingCellVm cell) {
    final slotHeight = _answerSlotHeightForCell(cell);
    if (_isObjectiveAnswer(
      answer: cell.answer,
      answerMode: cell.answerMode,
    )) {
      return SizedBox(
        height: slotHeight,
        child: _buildObjectiveAnswerFlutter(cell),
      );
    }
    final render = _answerRenders[cell.key];
    if (_isRawAnswerImageCell(cell)) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => unawaited(_openRawAnswerImageDialog(cell)),
        child: LayoutBuilder(
          builder: (context, constraints) => _buildAnswerNetworkImage(
            url: cell.answerImageUrl,
            rawWidth: (cell.answerImageWidth ?? 0) <= 0
                ? 1.0
                : cell.answerImageWidth!.toDouble(),
            rawHeight: (cell.answerImageHeight ?? 0) <= 0
                ? 1.0
                : cell.answerImageHeight!.toDouble(),
            pixelRatio: cell.answerImagePixelRatio != null &&
                    cell.answerImagePixelRatio!.isFinite &&
                    cell.answerImagePixelRatio! > 0
                ? cell.answerImagePixelRatio!
                : 1.0,
            styleVersion: '',
            slotHeight: slotHeight,
            constraints: constraints,
            fallbackBuilder: () => _buildAnswerFallback(cell),
          ),
        ),
      );
    }
    if (render != null && render.hasImage) {
      if (render.styleVersion.trim() != kUnifiedAnswerRenderStyleVersion) {
        return _buildAnswerFallback(cell);
      }
      return LayoutBuilder(
        builder: (context, constraints) => _buildAnswerNetworkImage(
          url: render.url,
          rawWidth: render.width <= 0 ? 1.0 : render.width.toDouble(),
          rawHeight: render.height <= 0 ? 1.0 : render.height.toDouble(),
          pixelRatio: render.pixelRatio <= 0
              ? _answerRenderDefaultPixelRatio
              : render.pixelRatio,
          styleVersion: render.styleVersion,
          displayWidthDp: render.displayWidthDp,
          displayHeightDp: render.displayHeightDp,
          slotHeight: slotHeight,
          constraints: constraints,
          fallbackBuilder: () => _buildAnswerFallback(cell),
          leftPadding: 16,
        ),
      );
    }
    return _buildAnswerFallback(cell);
  }

  Widget _buildAnswerFallback(_RightSheetGradingCellVm cell) {
    // 사전 렌더 PNG가 아직 없거나 네트워크에서 불러오지 못해도 정답
    // 자체는 숨기지 않는다. 기존 LaTeX 텍스트 렌더러로 즉시 폴백한다.
    return _buildInlineAnswerText(cell);
  }

  Widget _buildInlineAnswerText(_RightSheetGradingCellVm cell) {
    final answer = cell.answer.trim().isEmpty ? '-' : cell.answer.trim();
    final setParts = _splitSetAnswerParts(answer);
    if (setParts.isNotEmpty) {
      return SizedBox(
        height: _answerSlotHeightForCell(cell),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < setParts.length; i += 1) ...[
                if (i > 0) const SizedBox(height: 4),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 34,
                      child: Text(
                        setParts[i].label,
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                          color: _rsText,
                          fontFamily: 'ChosunNm',
                          fontWeight: FontWeight.w700,
                          fontSize: 20,
                          height: 1.2,
                        ),
                      ),
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: LatexTextRenderer(
                        _normalizeAnswerForOverflowDisplay(setParts[i].value),
                        textAlign: TextAlign.start,
                        overflow: TextOverflow.visible,
                        softWrap: true,
                        enableDisplayMath: false,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        inlineMathScale: 0.88,
                        fractionInlineMathScale: 1.0,
                        style: const TextStyle(
                          color: _rsText,
                          fontFamily: 'ChosunNm',
                          fontWeight: FontWeight.w700,
                          fontSize: 23,
                          height: 1.18,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      );
    }
    return SizedBox(
      height: _answerSlotHeightForCell(cell),
      child: Align(
        alignment: Alignment.centerLeft,
        child: LatexTextRenderer(
          _normalizeAnswerForOverflowDisplay(answer),
          textAlign: TextAlign.left,
          overflow: TextOverflow.visible,
          softWrap: true,
          enableDisplayMath: false,
          crossAxisAlignment: CrossAxisAlignment.start,
          inlineMathScale: 0.9,
          fractionInlineMathScale: 1.02,
          style: const TextStyle(
            color: _rsText,
            fontFamily: 'ChosunNm',
            fontWeight: FontWeight.w700,
            fontSize: 25,
            height: 1.1,
          ),
        ),
      ),
    );
  }

  Widget _buildAnswerListRow(
    _RightSheetGradingCellVm cell, {
    required int pageNumber,
  }) {
    final state = _normalizeState(_gradingStates[cell.key]);
    final colors = _resolveAnswerRowStyle(state);
    final questionLabel = cell.displayQuestionLabel;
    final answerSlotHeight = _answerSlotHeightForCell(cell);
    final baselineState = _baselineStates[cell.key] ?? '';
    final correctedRetry = _isCorrectedRetryKey(cell.key);
    final correctionAttemptNumber = _correctionAttemptNumbers[cell.key] ?? 0;
    return _RightSheetAnswerListRow(
      questionLabel: questionLabel,
      editLocked: _gradingEditLocked,
      state: state,
      baselineState: baselineState,
      correctedRetry: correctedRetry,
      correctionAttemptNumber: correctionAttemptNumber,
      backgroundColor: colors.background,
      borderColor: colors.border,
      answerSlotHeight: answerSlotHeight,
      hasSourceInfo: cell.sourceInfo.isNotEmpty,
      solutionOpening: _openingSolutionCellKey == cell.key,
      solutionOpenBlocked:
          _answerPdfOpening || _openingSolutionCellKey.isNotEmpty,
      onOpenSolution: () => _openCellSolution(cell, pageNumber: pageNumber),
      onReportIssue: () => unawaited(_openQuestionIssueReportDialog(cell)),
      onToggleState: () => unawaited(_toggleCellState(cell.key)),
      onShowSourceInfo: () => unawaited(_openQuestionSourceInfoDialog(cell)),
      answerChild: _buildAnswerImageOrFallback(cell),
    );
  }

  Widget _buildPageDividerLabel(
    _RightSheetGradingPageVm page, {
    required bool isFirst,
  }) {
    return Padding(
      padding: EdgeInsets.only(
        top: isFirst ? 0 : 12,
        bottom: 8,
      ),
      child: Row(
        children: [
          if (!isFirst)
            const Expanded(
              child: Divider(height: 1, thickness: 1, color: _rsBorder),
            )
          else
            const Spacer(),
          const SizedBox(width: 10),
          Text(
            'p.${page.pageNumber}',
            style: const TextStyle(
              color: _rsTextSub,
              fontWeight: FontWeight.w800,
              fontSize: 13,
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAnswerPageSection(
    _RightSheetGradingPageVm page, {
    required bool isFirst,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildPageDividerLabel(
          page,
          isFirst: isFirst,
        ),
        for (int i = 0; i < page.cells.length; i++) ...[
          _buildAnswerListRow(page.cells[i], pageNumber: page.pageNumber),
          if (i != page.cells.length - 1) const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _buildAnswerList(List<_RightSheetGradingPageVm> pages) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (int i = 0; i < pages.length; i++)
          _buildAnswerPageSection(
            pages[i],
            isFirst: i == 0,
          ),
      ],
    );
  }

  Widget _buildActionButtons() {
    final fabStyle = _rightSheetFabColors(context);
    Widget button({
      required String label,
      required VoidCallback onTap,
      bool filled = false,
    }) {
      return SizedBox(
        height: 51,
        child: OutlinedButton(
          onPressed: _actionBusy ? null : onTap,
          style: OutlinedButton.styleFrom(
            backgroundColor: filled ? _rsAccent : Colors.transparent,
            side: BorderSide(color: filled ? _rsAccent : fabStyle.border),
            foregroundColor: filled ? Colors.white : fabStyle.text,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 0),
            minimumSize: const Size(102, 51),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 18.5,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        button(
          label: _actionBusy ? '완료중' : '완료',
          onTap: () => unawaited(_runAction('complete')),
        ),
        const SizedBox(width: 8),
        button(
          label: _actionBusy ? '확인중' : '확인',
          onTap: () => unawaited(_runAction('confirm')),
          filled: true,
        ),
      ],
    );
  }

  static const double _gradingBottomBarHeight = 75;
  static const double _gradingAnswerListBottomInset = 4;
  static const double _gradingBottomBarScrollPadding =
      _gradingBottomBarHeight + _gradingAnswerListBottomInset;
  static const double _gradingSheetHorizontalInset = 10;

  Widget _buildGradingBottomBar(RightSideSheetTestGradingSession session) {
    if (_answerListReadOnly) return const SizedBox.shrink();
    return FabStyleGlassPanel(
      useFabTabBarBackground: true,
      borderRadius: BorderRadius.zero,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: _buildScoreCalculator(session)),
          const SizedBox(width: 12),
          _buildActionButtons(),
        ],
      ),
    );
  }

  Widget _buildGradingAnswerBody({
    required RightSideSheetTestGradingSession session,
    required List<_RightSheetGradingPageVm> pages,
    required double topScrollPadding,
  }) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: SingleChildScrollView(
            padding: EdgeInsets.only(
              top: topScrollPadding,
              bottom: _gradingBottomBarScrollPadding,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildSessionHeader(session),
                const SizedBox(height: 22),
                if (pages.isNotEmpty) _buildAnswerList(pages),
                if (pages.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      _wrongOnly && _baselineStates.isNotEmpty
                          ? '첫 채점에서 틀렸거나 미풀이였던 문항이 없습니다.'
                          : '검색 결과가 없습니다.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: _rsTextSub,
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Positioned(
          left: -_gradingSheetHorizontalInset,
          right: -_gradingSheetHorizontalInset,
          bottom: 0,
          child: _buildGradingBottomBar(session),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    _scheduleSuggestionOverlaySync();
    final fabStyle = _rightSheetFabColors(context);
    final session = widget.session;
    final pages = _visiblePages();

    if (session == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildSearchHeader(),
            const SizedBox(height: 24),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: fabStyle.panel,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: fabStyle.border),
                ),
                alignment: Alignment.center,
                padding: const EdgeInsets.all(16),
                child: Text(
                  '테스트 채점 세션이 없습니다.\n수업 화면에서 테스트 제출 카드를 눌러 채점을 시작하세요.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: fabStyle.subText,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    _syncGradingSearchOverlayHeight();

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 0),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: _buildGradingAnswerBody(
              session: session,
              pages: pages,
              topScrollPadding: _gradingSearchOverlayHeight,
            ),
          ),
          Positioned(
            top: 0,
            left: -_gradingSheetHorizontalInset,
            right: -_gradingSheetHorizontalInset,
            child: _buildGradingSearchOverlay(),
          ),
        ],
      ),
    );
  }
}

class _AnswerKeyPdfShortcutExplorer extends StatefulWidget {
  final List<_BookItem> books;
  final List<_GradeOption> grades;
  final Map<String, Map<String, String>> pdfPathByBookAndGrade;
  final VoidCallback onAddBook;
  final VoidCallback onEditBook;
  final VoidCallback onEditGrades;
  final VoidCallback onDeleteBook;
  final void Function(String bookId) onSelectBook;
  final void Function({required String bookId, required int delta})
      onBookGradeDelta;
  final void Function(_BookItem book) onOpenBook;
  final void Function(int oldIndex, int newIndex) onReorderBooks;

  const _AnswerKeyPdfShortcutExplorer({
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
  State<_AnswerKeyPdfShortcutExplorer> createState() =>
      _AnswerKeyPdfShortcutExplorerState();
}

class _AnswerKeyPdfShortcutExplorerState
    extends State<_AnswerKeyPdfShortcutExplorer> {
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
    final border = showRightDivider
        ? Border(right: BorderSide(color: _rsBorder.withOpacity(0.9)))
        : null;

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
  final void Function({required String bookId, required int delta})
      onBookGradeDelta;
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
            const Text('책',
                style: TextStyle(
                    color: _rsText, fontSize: 15, fontWeight: FontWeight.w900)),
            const SizedBox(width: 8),
            Text('${books.length}권',
                style: const TextStyle(
                    color: _rsTextSub,
                    fontSize: 12,
                    fontWeight: FontWeight.w800)),
          ],
        ),
        const SizedBox(height: 8),
        if (books.isEmpty)
          const Text(
            '추가된 책이 없습니다.',
            style: TextStyle(
                color: _rsTextSub, fontSize: 12, fontWeight: FontWeight.w700),
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
                  final curved = CurvedAnimation(
                      parent: animation, curve: Curves.easeOutCubic);
                  return AnimatedBuilder(
                    animation: curved,
                    builder: (context, _) {
                      final v = curved.value;
                      return Transform.translate(
                        offset: Offset(0, -4 * v),
                        child: Transform.scale(
                          scale: 1.0 + 0.02 * v,
                          child: Material(
                            color: context.yggSurfaceBase,
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
                  final gradeIdx = grades.isEmpty
                      ? 0
                      : b.gradeIndex.clamp(0, grades.length - 1);

                  // 요청: 연결된 PDF가 있는 학년만 보이도록(순회/표시) "연결된 학년"을 먼저 산출
                  final paths = pdfPathByBookAndGrade[b.id];
                  final linkedIndices = <int>[];
                  if (paths != null && paths.isNotEmpty && grades.isNotEmpty) {
                    for (int i = 0; i < grades.length; i++) {
                      final k = grades[i].key;
                      final p = paths[k];
                      if (p != null && p.trim().isNotEmpty)
                        linkedIndices.add(i);
                    }
                  }

                  final hasAnyLinked = linkedIndices.isNotEmpty;
                  final effectiveIdx = hasAnyLinked
                      ? (linkedIndices.contains(gradeIdx)
                          ? gradeIdx
                          : linkedIndices.first)
                      : 0;
                  final gradeLabel =
                      hasAnyLinked ? grades[effectiveIdx].label : '-';
                  final linked = hasAnyLinked;

                  return ReorderableDelayedDragStartListener(
                    key: ValueKey(b.id),
                    index: index,
                    child: Padding(
                      padding: EdgeInsets.only(
                          bottom: (index == books.length - 1) ? 0 : 8),
                      child: _BookCard(
                        item: b,
                        gradeLabel: gradeLabel,
                        onGradeDelta: (delta) =>
                            onBookGradeDelta(bookId: b.id, delta: delta),
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
  static const double _bookCardMinHeight = 104.0;
  static const double _gradeSwipeDistanceThreshold = 30.0;
  static const double _gradeSwipeVelocityThreshold = 240.0;
  double _gradeDragDx = 0.0;
  bool _gradeDragMovedByDistance = false;

  void _resetGradeDrag() {
    _gradeDragDx = 0.0;
    _gradeDragMovedByDistance = false;
  }

  void _triggerGradeDelta(int delta) {
    if (delta == 0) return;
    _gradeDragMovedByDistance = true;
    widget.onGradeDelta(delta);
  }

  void _handleGradeDragStart(DragStartDetails _) {
    _resetGradeDrag();
  }

  void _handleGradeDragUpdate(DragUpdateDetails d) {
    _gradeDragDx += d.delta.dx;
    if (_gradeDragDx <= -_gradeSwipeDistanceThreshold) {
      final steps = (_gradeDragDx.abs() / _gradeSwipeDistanceThreshold).floor();
      _gradeDragDx += _gradeSwipeDistanceThreshold * steps;
      _triggerGradeDelta(steps);
    } else if (_gradeDragDx >= _gradeSwipeDistanceThreshold) {
      final steps = (_gradeDragDx.abs() / _gradeSwipeDistanceThreshold).floor();
      _gradeDragDx -= _gradeSwipeDistanceThreshold * steps;
      _triggerGradeDelta(-steps);
    }
  }

  void _handleGradeDragEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0.0;
    if (!_gradeDragMovedByDistance && v.abs() >= _gradeSwipeVelocityThreshold) {
      _triggerGradeDelta(v < 0 ? 1 : -1);
    }
    _resetGradeDrag();
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
                style: TextStyle(
                    color: fg, fontSize: 13, fontWeight: FontWeight.w900),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                textAlign: TextAlign.right,
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
              widget.onGradeDelta(dx < 0 ? 1 : -1);
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
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragStart: _handleGradeDragStart,
              onHorizontalDragUpdate: _handleGradeDragUpdate,
              onHorizontalDragEnd: _handleGradeDragEnd,
              onHorizontalDragCancel: _resetGradeDrag,
              child: ConstrainedBox(
                constraints:
                    const BoxConstraints(minHeight: _bookCardMinHeight),
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
                                Expanded(
                                  child: LatexTextRenderer(
                                    widget.item.name,
                                    style: const TextStyle(
                                      color: _rsText,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w900,
                                    ),
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
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      LatexTextRenderer(
                        widget.item.description,
                        style: const TextStyle(
                          color: _rsTextSub,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _QuestionSourceInfoDialog extends StatelessWidget {
  final String questionLabel;
  final Map<String, String> sourceInfo;
  final VoidCallback onClose;

  const _QuestionSourceInfoDialog({
    required this.questionLabel,
    required this.sourceInfo,
    required this.onClose,
  });

  String _value(String key) => (sourceInfo[key] ?? '').trim();

  @override
  Widget build(BuildContext context) {
    final kind = _value('sourceKind').toLowerCase();
    final isExam = kind == 'exam' || kind == 'hwpx';
    final rows = isExam
        ? <({String label, String value})>[
            (label: '학교', value: _value('schoolName')),
            (label: '연도', value: _value('year')),
            (label: '시험', value: _value('examName')),
            (label: '원문항', value: _value('originalQuestionNumber')),
          ]
        : <({String label, String value})>[
            (label: '교재명', value: _value('bookName')),
            (label: '원문항', value: _value('originalQuestionNumber')),
            (label: '난이도', value: _value('difficulty')),
            (label: '유형', value: _value('typeName')),
          ];
    final visibleRows =
        rows.where((row) => row.value.trim().isNotEmpty).toList();

    return AlertDialog(
      backgroundColor: context.yggSurfaceBase,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: _rsBorder),
      ),
      titlePadding: const EdgeInsets.fromLTRB(22, 20, 22, 0),
      contentPadding: const EdgeInsets.fromLTRB(22, 16, 22, 4),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      title: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: _rsAccent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _rsAccent.withValues(alpha: 0.26)),
            ),
            child: const Icon(
              Icons.info_outline_rounded,
              color: _rsAccent,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '$questionLabel번 문항 출처',
              style: const TextStyle(
                color: _rsText,
                fontSize: 18,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _rsPanelBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _rsBorder),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: visibleRows.isEmpty
                ? const Text(
                    '등록된 세부 출처 정보가 없습니다.',
                    style: TextStyle(
                      color: _rsTextSub,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < visibleRows.length; i++) ...[
                        _QuestionSourceInfoRow(
                          label: visibleRows[i].label,
                          value: visibleRows[i].value,
                        ),
                        if (i != visibleRows.length - 1)
                          const Divider(
                            height: 18,
                            thickness: 1,
                            color: _rsBorder,
                          ),
                      ],
                    ],
                  ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: onClose,
          style: TextButton.styleFrom(foregroundColor: _rsAccent),
          child: const Text('확인'),
        ),
      ],
    );
  }
}

class _QuestionSourceInfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _QuestionSourceInfoRow({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 74,
          child: Text(
            label,
            style: const TextStyle(
              color: _rsTextSub,
              fontSize: 12,
              fontWeight: FontWeight.w900,
              height: 1.3,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: _rsText,
              fontSize: 14,
              fontWeight: FontWeight.w800,
              height: 1.3,
            ),
          ),
        ),
      ],
    );
  }
}

class _QuestionIssueTypeChip extends StatelessWidget {
  final String label;
  final bool selected;
  final bool enabled;
  final ValueChanged<bool> onSelected;

  const _QuestionIssueTypeChip({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final bg = selected ? const Color(0xFF1B6B63) : const Color(0xFF2A2A2A);
    final borderColor =
        selected ? _rsAccent.withValues(alpha: 0.7) : Colors.transparent;
    final textColor = selected ? Colors.white : const Color(0xFFCDD5D5);
    return Opacity(
      opacity: enabled ? 1.0 : 0.55,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: enabled ? () => onSelected(!selected) : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: borderColor),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: _rsAccent.withValues(alpha: 0.12),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ]
                  : const <BoxShadow>[],
            ),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: textColor,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RawAnswerImageZoomDialog extends StatefulWidget {
  final String title;
  final String url;
  final VoidCallback onClose;

  const _RawAnswerImageZoomDialog({
    required this.title,
    required this.url,
    required this.onClose,
  });

  @override
  State<_RawAnswerImageZoomDialog> createState() =>
      _RawAnswerImageZoomDialogState();
}

class _RawAnswerImageZoomDialogState extends State<_RawAnswerImageZoomDialog> {
  static const double _initialScale = 2.0;
  late final TransformationController _controller;
  bool _didSetInitialTransform = false;

  @override
  void initState() {
    super.initState();
    _controller = TransformationController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _rsPanelBg,
      insetPadding: const EdgeInsets.all(20),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: _rsBorder),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920, maxHeight: 720),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _rsText,
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close_rounded),
                    color: _rsTextSub,
                    tooltip: '닫기',
                  ),
                ],
              ),
            ),
            Flexible(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    color: _rsFieldBg,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        _setInitialCenteredTransform(constraints);
                        return InteractiveViewer(
                          transformationController: _controller,
                          boundaryMargin: const EdgeInsets.all(320),
                          minScale: 0.8,
                          maxScale: 8,
                          child: Center(
                            child: Image.network(
                              widget.url,
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.high,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _setInitialCenteredTransform(BoxConstraints constraints) {
    if (_didSetInitialTransform) return;
    final width = constraints.maxWidth;
    final height = constraints.maxHeight;
    if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
      return;
    }
    _didSetInitialTransform = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.value = Matrix4.identity()
        ..translate(
          width * (1 - _initialScale) / 2,
          height * (1 - _initialScale) / 2,
        )
        ..scale(_initialScale);
    });
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
            child: Text('이름',
                style: TextStyle(
                    color: _rsTextSub,
                    fontSize: 12,
                    fontWeight: FontWeight.w800)),
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
            style: TextStyle(
                color: _rsTextSub, fontSize: 12, fontWeight: FontWeight.w800),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: 6),
          Text(
            '교재 탭에서 정답 링크를 등록하면 여기서 바로 열 수 있습니다.',
            style: TextStyle(
                color: Colors.white38,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                height: 1.3),
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
              const Icon(Icons.picture_as_pdf_outlined,
                  color: Colors.white54, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.item.name,
                  style: const TextStyle(
                      color: _rsText,
                      fontSize: 12,
                      fontWeight: FontWeight.w700),
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
  const _BookItem(
      {required this.id,
      required this.name,
      required this.description,
      required this.gradeIndex});

  _BookItem copyWith(
          {String? id, String? name, String? description, int? gradeIndex}) =>
      _BookItem(
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
      backgroundColor: context.yggSurfaceBase,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: _rsBorder),
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      title: const Text(
        '책 선택',
        style: TextStyle(
            color: _rsText, fontSize: 18, fontWeight: FontWeight.w900),
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
      widget.books[i].id: (widget.grades.isEmpty
          ? 0
          : widget.books[i].gradeIndex.clamp(0, widget.grades.length - 1)),
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
              final gradeLabel =
                  widget.grades.isEmpty ? '-' : widget.grades[gradeIdx].label;
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
                              style: const TextStyle(
                                  color: _rsText,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w900),
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              b.description,
                              style: const TextStyle(
                                  color: _rsTextSub,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  height: 1.25),
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
                        onSelected: (i) =>
                            setState(() => _gradeIndexByBookId[b.id] = i),
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
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: _rsBorder)),
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
                      style: const TextStyle(
                          color: _rsTextSub,
                          fontSize: 13,
                          fontWeight: FontWeight.w900),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    ),
                  ),
                  const SizedBox(width: 2),
                  const Icon(Icons.keyboard_arrow_down,
                      size: 16, color: _rsTextSub),
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
  State<_AnswerKeyGradesEditDialog> createState() =>
      _AnswerKeyGradesEditDialogState();
}

class _AnswerKeyGradesEditDialogState
    extends State<_AnswerKeyGradesEditDialog> {
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
      backgroundColor: context.yggSurfaceBase,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: _rsBorder),
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      title: const Text(
        '과정 편집',
        style: TextStyle(
            color: _rsText, fontSize: 18, fontWeight: FontWeight.w900),
      ),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '여기에 과정명을 입력하세요. (예: 기본, 심화, 내신, 수능)\n빈 항목은 저장 시 제외됩니다.',
              style: TextStyle(
                  color: _rsTextSub,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  height: 1.35),
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
                      margin: EdgeInsets.only(
                          bottom: index == _keys.length - 1 ? 0 : 8),
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
                            child: const Icon(Icons.drag_indicator,
                                color: Colors.white24, size: 18),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: _ctrls[index],
                              style: const TextStyle(
                                  color: _rsText, fontWeight: FontWeight.w800),
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
                            icon: const Icon(Icons.close,
                                color: Colors.white38, size: 18),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                                minWidth: 32, minHeight: 32),
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
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child:
              const Text('저장', style: TextStyle(fontWeight: FontWeight.w900)),
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
  late Map<String, String> _paths =
      Map<String, String>.from(widget.initialPaths);
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
    final maxH = (MediaQuery.of(context).size.height * 0.78)
        .clamp(360.0, 620.0)
        .toDouble();
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
          style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w900,
              height: 1.0),
        ),
      );
    }

    return AlertDialog(
      backgroundColor: context.yggSurfaceBase,
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
          const Text('PDF 수정',
              style: TextStyle(
                  color: _rsText, fontSize: 18, fontWeight: FontWeight.w900)),
          const SizedBox(height: 6),
          LatexTextRenderer(
            widget.book.name,
            style: const TextStyle(
                color: _rsTextSub, fontSize: 13, fontWeight: FontWeight.w800),
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
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
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
                            onPressed:
                                (!_busy && linked) ? () => _detach(g) : null,
                            style: TextButton.styleFrom(
                              foregroundColor: const Color(0xFFFFB4B4),
                              minimumSize: const Size(0, 36),
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 10),
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
      backgroundColor: context.yggSurfaceBase,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: _rsBorder),
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      title: const Text(
        '책 추가',
        style: TextStyle(
            color: _rsText, fontSize: 18, fontWeight: FontWeight.w900),
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
                labelStyle: const TextStyle(
                    color: _rsTextSub, fontWeight: FontWeight.w800),
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
                labelStyle: const TextStyle(
                    color: _rsTextSub, fontWeight: FontWeight.w800),
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
            Navigator.of(context).pop<_BookItem>(_BookItem(
                id: '', name: name, description: desc, gradeIndex: 0));
          },
          style: FilledButton.styleFrom(
            backgroundColor: _rsAccent,
            foregroundColor: Colors.white,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child:
              const Text('추가', style: TextStyle(fontWeight: FontWeight.w900)),
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
    for (final b in widget.initial)
      ImeAwareTextEditingController(text: b.description),
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
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('책 이름은 비워둘 수 없습니다.')));
        return;
      }
      updated.add(widget.initial[i].copyWith(name: name, description: desc));
    }
    Navigator.of(context).pop<List<_BookItem>>(updated);
  }

  InputDecoration _fieldDeco(String label) => InputDecoration(
        labelText: label,
        labelStyle:
            const TextStyle(color: _rsTextSub, fontWeight: FontWeight.w800),
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
              style: const TextStyle(
                  color: _rsTextSub, fontSize: 12, fontWeight: FontWeight.w900),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: context.yggSurfaceBase,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: _rsBorder),
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      title: const Text(
        '책 수정',
        style: TextStyle(
            color: _rsText, fontSize: 18, fontWeight: FontWeight.w900),
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
                                  style: const TextStyle(
                                      color: _rsTextSub,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w800),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              OutlinedButton.icon(
                                onPressed: widget.onEditPdf == null
                                    ? null
                                    : () {
                                        final b0 = widget.initial[index];
                                        final name =
                                            _nameCtrls[index].text.trim();
                                        final desc =
                                            _descCtrls[index].text.trim();
                                        final book = b0.copyWith(
                                          name:
                                              name.isNotEmpty ? name : b0.name,
                                          description: desc,
                                        );
                                        unawaited(widget.onEditPdf!(book));
                                      },
                                icon: const Icon(Icons.picture_as_pdf_outlined,
                                    size: 16),
                                label: const Text('PDF 수정'),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.white70,
                                  side: BorderSide(
                                      color: _rsBorder.withOpacity(0.9)),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10)),
                                  minimumSize: const Size(0, 32),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10),
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  visualDensity: VisualDensity.compact,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _nameCtrls[index],
                            style: const TextStyle(
                                color: _rsText, fontWeight: FontWeight.w800),
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
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child:
              const Text('저장', style: TextStyle(fontWeight: FontWeight.w900)),
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
        Text(title,
            style: const TextStyle(
                color: _rsText, fontSize: 18, fontWeight: FontWeight.w900)),
        const SizedBox(height: 6),
        Text(subtitle,
            style: const TextStyle(
                color: _rsTextSub, fontSize: 13, fontWeight: FontWeight.w800)),
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
        final ok = await widget.onAttach(
            bookIndex: bi, gradeIndex: e.key, file: e.value);
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
    final maxH = (MediaQuery.of(context).size.height * 0.78)
        .clamp(380.0, 680.0)
        .toDouble();

    final int? selectedBookIndex = _bookIndex;
    final _BookItem? selectedBook = (selectedBookIndex != null &&
            selectedBookIndex >= 0 &&
            selectedBookIndex < books.length)
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
                            style: const TextStyle(
                                color: _rsText,
                                fontSize: 14,
                                fontWeight: FontWeight.w900),
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
                    const Icon(Icons.chevron_right,
                        color: Colors.white24, size: 22),
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
                LatexTextRenderer(
                  b.name,
                  style: const TextStyle(
                      color: _rsText,
                      fontSize: 14,
                      fontWeight: FontWeight.w900),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                Text(
                  '변경 예정: ${_pendingByGradeIndex.length}개',
                  style: const TextStyle(
                      color: _rsTextSub,
                      fontSize: 12,
                      fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                const Text(
                  '각 과정 행의 “드롭/찾기”로 PDF를 지정한 뒤, 우측 아래 “저장”으로 한 번에 반영하세요.',
                  style: TextStyle(
                      color: Colors.white38,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      height: 1.25),
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
                  final fileLabel =
                      linked ? widget.basenameOf(existing!) : '미연결';
                  final pending = _pendingByGradeIndex[index];
                  final hasPending =
                      pending != null && pending.path.trim().isNotEmpty;

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
                                    color: (linked || hasPending)
                                        ? _rsTextSub
                                        : Colors.white24,
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
                                    const Icon(Icons.arrow_right_alt,
                                        size: 16, color: _rsAccent),
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
                                  setState(
                                      () => _pendingByGradeIndex[index] = xf);
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
                                        setState(() =>
                                            _pendingByGradeIndex[index] = xf);
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
    final subtitle =
        (_step == 0) ? '1/2 · 책을 선택하세요' : '2/2 · 과정별 PDF를 지정하고 저장하세요';
    final desiredH = (_step == 0)
        ? (220.0 + books.length * 78.0)
        : (260.0 + grades.length * 104.0);
    final bodyHeight = desiredH.clamp(360.0, maxH).toDouble();

    return AlertDialog(
      backgroundColor: context.yggSurfaceBase,
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
            onPressed:
                (_busy || _pendingByGradeIndex.isEmpty) ? null : _savePending,
            style: FilledButton.styleFrom(
              backgroundColor: _rsAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: Text(
              _pendingByGradeIndex.isEmpty
                  ? '저장'
                  : '저장 (${_pendingByGradeIndex.length})',
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
