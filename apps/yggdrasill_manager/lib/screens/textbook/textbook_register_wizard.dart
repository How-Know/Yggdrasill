// Multi-step wizard for registering a new textbook.
//
// Step 1 — 메타+표지: series dropdown, book name, grade label, textbook type,
//                     page offset, and an optional cover image.
// Step 2 — 파일:       body / answer / solution PDFs with the existing
//                     dual-track upload pipeline (signed URL → PUT → finalize).
//                     Every PDF slot is optional — you can register the book
//                     with none of them and upload later via the migration
//                     pane. Legacy URL fields are kept for books that still
//                     live on Dropbox.
// Step 3 — 단원 구조:   대/중 units with A/B/C sub-sections (쎈) — only start
//                     and end pages are collected per sub-section.
//
// On finish, the service layer writes:
//   * resource_files
//   * resource_file_links (body / ans / sol / cover composite grades)
//   * textbook_metadata.payload (series + unit tree)
// Then any selected PDFs are uploaded via [TextbookPdfService].

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../services/textbook_book_registry.dart';
import '../../services/textbook_pdf_service.dart';
import '../../services/textbook_series_catalog.dart';

class TextbookRegisterWizard extends StatefulWidget {
  const TextbookRegisterWizard({super.key, this.defaultAcademyId});

  /// Optional pre-filled academy id. If null, we'll try to pull the current
  /// user's academy from the most recent `resource_files` row.
  final String? defaultAcademyId;

  /// Opens the wizard as a full-screen dialog and returns the newly created
  /// book id when the user finishes. Null if the user cancels.
  static Future<TextbookBookRegistryResult?> show(
    BuildContext context, {
    String? defaultAcademyId,
  }) {
    return showDialog<TextbookBookRegistryResult>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF131315),
        insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 40),
        child: SizedBox(
          width: 960,
          height: 720,
          child: TextbookRegisterWizard(defaultAcademyId: defaultAcademyId),
        ),
      ),
    );
  }

  @override
  State<TextbookRegisterWizard> createState() => _TextbookRegisterWizardState();
}

class _TextbookRegisterWizardState extends State<TextbookRegisterWizard> {
  final _supabase = Supabase.instance.client;
  final _registry = TextbookBookRegistry();
  final _pdfService = TextbookPdfService();
  static const String _rootFolderValue = '__ROOT__';

  int _step = 0;
  bool _submitting = false;
  String? _submitError;

  // Step 1 fields -----------------------------------------------------------
  String _seriesKey = kTextbookSeriesCatalog.first.key;
  final _bookNameCtrl = TextEditingController();
  final _bookDescCtrl = TextEditingController();
  final _gradeLabelCtrl = TextEditingController();
  String _textbookType = '문제집';
  final _pageOffsetCtrl = TextEditingController(text: '0');
  String? _coverLocalPath;
  String? _coverExistingUrl;
  bool _loadingGrades = true;
  List<String> _gradeOptions = const <String>[];
  bool _loadingFolders = true;
  List<_ResourceFolderOption> _folderOptions = const <_ResourceFolderOption>[];
  String _selectedFolderId = _rootFolderValue;

  String? _resolvedAcademyId;

  // Step 2 fields -----------------------------------------------------------
  String? _bodyPdfPath;
  String? _answerPdfPath;
  String? _solutionPdfPath;
  final _bodyLegacyCtrl = TextEditingController();
  final _answerLegacyCtrl = TextEditingController();
  final _solutionLegacyCtrl = TextEditingController();

  // Step 3 fields -----------------------------------------------------------
  final List<_BigUnitEdit> _bigUnits = <_BigUnitEdit>[];

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _resolveAcademyId();
    await Future.wait<void>([
      _loadGradeOptions(),
      _loadFolderOptions(),
    ]);
    if (_bigUnits.isEmpty) {
      _addBigUnit(silent: true);
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadGradeOptions() async {
    try {
      final data = await _supabase
          .from('answer_key_grades')
          .select('label,order_index')
          .order('order_index');
      final rows = (data as List).cast<Map<String, dynamic>>();
      final labels = <String>[];
      for (final r in rows) {
        final label = (r['label'] as String?)?.trim() ?? '';
        if (label.isEmpty) continue;
        labels.add(label);
      }
      if (!mounted) return;
      setState(() {
        _gradeOptions = labels;
        _loadingGrades = false;
        if (_gradeLabelCtrl.text.trim().isEmpty && labels.isNotEmpty) {
          _gradeLabelCtrl.text = labels.first;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingGrades = false);
    }
  }

  Future<void> _loadFolderOptions() async {
    final academyId = (_resolvedAcademyId ?? '').trim();
    if (academyId.isEmpty) {
      if (!mounted) return;
      setState(() {
        _loadingFolders = false;
        _folderOptions = const <_ResourceFolderOption>[];
        _selectedFolderId = _rootFolderValue;
      });
      return;
    }
    try {
      final dynamic data = await _supabase
          .from('resource_folders')
          .select('id,name,parent_id,order_index,category')
          .eq('academy_id', academyId)
          .or('category.is.null,category.eq.textbook')
          .order('order_index')
          .order('name');
      List<Map<String, dynamic>> rows = (data as List).cast<Map<String, dynamic>>();
      if (rows.isEmpty) {
        final all = await _supabase
            .from('resource_folders')
            .select('id,name,parent_id,order_index,category')
            .eq('academy_id', academyId)
            .order('order_index')
            .order('name');
        rows = (all as List).cast<Map<String, dynamic>>().where((row) {
          final category = (row['category'] as String?)?.trim();
          return category == null || category.isEmpty || category == 'textbook';
        }).toList();
      }

      final children = <String?, List<Map<String, dynamic>>>{};
      for (final row in rows) {
        final parentId = (row['parent_id'] as String?)?.trim();
        children.putIfAbsent(parentId?.isEmpty == true ? null : parentId, () => <Map<String, dynamic>>[]).add(row);
      }
      for (final list in children.values) {
        list.sort((a, b) {
          final ai = (a['order_index'] as num?)?.toInt() ?? 1 << 20;
          final bi = (b['order_index'] as num?)?.toInt() ?? 1 << 20;
          if (ai != bi) return ai.compareTo(bi);
          final an = (a['name'] as String?)?.toLowerCase() ?? '';
          final bn = (b['name'] as String?)?.toLowerCase() ?? '';
          return an.compareTo(bn);
        });
      }

      final options = <_ResourceFolderOption>[];
      void walk(String? parentId, int depth) {
        for (final row in children[parentId] ?? const <Map<String, dynamic>>[]) {
          final id = (row['id'] as String?)?.trim() ?? '';
          final name = (row['name'] as String?)?.trim() ?? '';
          if (id.isEmpty || name.isEmpty) continue;
          options.add(_ResourceFolderOption(
            id: id,
            name: name,
            depth: depth,
          ));
          walk(id, depth + 1);
        }
      }

      walk(null, 0);
      if (!mounted) return;
      setState(() {
        _loadingFolders = false;
        _folderOptions = options;
        if (!_folderOptions.any((folder) => folder.id == _selectedFolderId)) {
          _selectedFolderId = _rootFolderValue;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingFolders = false;
        _folderOptions = const <_ResourceFolderOption>[];
        _selectedFolderId = _rootFolderValue;
      });
    }
  }

  Future<void> _resolveAcademyId() async {
    if (widget.defaultAcademyId != null &&
        widget.defaultAcademyId!.trim().isNotEmpty) {
      _resolvedAcademyId = widget.defaultAcademyId!.trim();
      return;
    }
    try {
      final row = await _supabase
          .from('resource_files')
          .select('academy_id')
          .limit(1)
          .maybeSingle();
      String? id;
      if (row != null) {
        id = (row['academy_id'] as String?)?.trim();
      }
      _resolvedAcademyId = id ?? '';
    } catch (_) {
      _resolvedAcademyId = null;
    }
  }

  @override
  void dispose() {
    _bookNameCtrl.dispose();
    _bookDescCtrl.dispose();
    _gradeLabelCtrl.dispose();
    _pageOffsetCtrl.dispose();
    _bodyLegacyCtrl.dispose();
    _answerLegacyCtrl.dispose();
    _solutionLegacyCtrl.dispose();
    for (final unit in _bigUnits) {
      unit.dispose();
    }
    super.dispose();
  }

  TextbookSeriesCatalogEntry get _series =>
      textbookSeriesByKey(_seriesKey) ?? kTextbookSeriesCatalog.first;

  void _addBigUnit({bool silent = false}) {
    final newUnit = _BigUnitEdit();
    newUnit.middles.add(_MidUnitEdit(series: _series));
    _bigUnits.add(newUnit);
    if (!silent) setState(() {});
  }

  void _removeBigUnit(int index) {
    setState(() {
      _bigUnits[index].dispose();
      _bigUnits.removeAt(index);
    });
  }

  void _addMidUnit(_BigUnitEdit parent) {
    setState(() {
      parent.middles.add(_MidUnitEdit(series: _series));
    });
  }

  void _removeMidUnit(_BigUnitEdit parent, int index) {
    setState(() {
      parent.middles[index].dispose();
      parent.middles.removeAt(index);
    });
  }

  Future<void> _pickCover() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: '교재 표지 이미지 선택',
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp'],
      withData: false,
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.first.path;
    if (path == null) return;
    setState(() {
      _coverLocalPath = path;
      _coverExistingUrl = null;
    });
  }

  Future<void> _pickPdf({required String kind}) async {
    final title = switch (kind) {
      'body' => '본문 PDF 선택',
      'ans' => '정답 PDF 선택',
      'sol' => '해설 PDF 선택',
      _ => 'PDF 선택',
    };
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: title,
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
      withData: false,
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.first.path;
    if (path == null) return;
    setState(() {
      switch (kind) {
        case 'body':
          _bodyPdfPath = path;
          break;
        case 'ans':
          _answerPdfPath = path;
          break;
        case 'sol':
          _solutionPdfPath = path;
          break;
      }
    });
  }

  int? get _pageOffsetValue {
    final t = _pageOffsetCtrl.text.trim();
    if (t.isEmpty || t == '-') return 0;
    return int.tryParse(t);
  }

  List<BigUnitInput> _buildBigUnitInputs() {
    final out = <BigUnitInput>[];
    for (var i = 0; i < _bigUnits.length; i += 1) {
      final big = _bigUnits[i];
      final midList = <MidUnitInput>[];
      for (var m = 0; m < big.middles.length; m += 1) {
        final mid = big.middles[m];
        final subList = <SubSectionInput>[];
        for (var s = 0; s < mid.subs.length; s += 1) {
          final sub = mid.subs[s];
          subList.add(SubSectionInput(
            order: s,
            subKey: sub.preset.key,
            displayName: sub.preset.displayName,
            startPage: _positiveInt(sub.startCtrl.text),
            endPage: _positiveInt(sub.endCtrl.text),
          ));
        }
        midList.add(MidUnitInput(
          midOrder: m,
          midName: mid.nameCtrl.text.trim(),
          subs: subList,
        ));
      }
      out.add(BigUnitInput(
        bigOrder: i,
        bigName: big.nameCtrl.text.trim(),
        middles: midList,
      ));
    }
    return out;
  }

  bool get _canProceedFromStep1 {
    if (_bookNameCtrl.text.trim().isEmpty) return false;
    if (_gradeLabelCtrl.text.trim().isEmpty) return false;
    if (_pageOffsetValue == null) return false;
    if ((_resolvedAcademyId ?? '').isEmpty) return false;
    return true;
  }

  bool get _canFinish {
    if (!_canProceedFromStep1) return false;
    if (_bigUnits.isEmpty) return false;
    for (final big in _bigUnits) {
      if (big.nameCtrl.text.trim().isEmpty) return false;
      for (final mid in big.middles) {
        if (mid.nameCtrl.text.trim().isEmpty) return false;
      }
    }
    return true;
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (!_canFinish) return;
    final academyId = _resolvedAcademyId ?? '';
    if (academyId.isEmpty) {
      setState(() => _submitError = 'academy_id를 확인할 수 없습니다.');
      return;
    }
    setState(() {
      _submitting = true;
      _submitError = null;
    });
    try {
      final registerInput = TextbookRegistrationInput(
        academyId: academyId,
        seriesKey: _series.key,
        bookName: _bookNameCtrl.text.trim(),
        description: _bookDescCtrl.text.trim().isEmpty
            ? null
            : _bookDescCtrl.text.trim(),
        gradeLabel: _gradeLabelCtrl.text.trim(),
        textbookType: _textbookType,
        pageOffset: _pageOffsetValue,
        bigUnits: _buildBigUnitInputs(),
        coverLocalPath: _coverLocalPath,
        coverExplicitUrl: _coverExistingUrl,
        parentFolderId:
            _selectedFolderId == _rootFolderValue ? null : _selectedFolderId,
        bodyLegacyUrl: _bodyLegacyCtrl.text.trim().isEmpty
            ? null
            : _bodyLegacyCtrl.text.trim(),
        answerLegacyUrl: _answerLegacyCtrl.text.trim().isEmpty
            ? null
            : _answerLegacyCtrl.text.trim(),
        solutionLegacyUrl: _solutionLegacyCtrl.text.trim().isEmpty
            ? null
            : _solutionLegacyCtrl.text.trim(),
      );
      final result = await _registry.registerBook(registerInput);

      await _uploadPdfIfPicked(
        filePath: _bodyPdfPath,
        kind: 'body',
        academyId: result.academyId,
        fileId: result.bookId,
        gradeLabel: result.gradeLabel,
        legacyUrl: registerInput.bodyLegacyUrl,
      );
      await _uploadPdfIfPicked(
        filePath: _answerPdfPath,
        kind: 'ans',
        academyId: result.academyId,
        fileId: result.bookId,
        gradeLabel: result.gradeLabel,
        legacyUrl: registerInput.answerLegacyUrl,
      );
      await _uploadPdfIfPicked(
        filePath: _solutionPdfPath,
        kind: 'sol',
        academyId: result.academyId,
        fileId: result.bookId,
        gradeLabel: result.gradeLabel,
        legacyUrl: registerInput.solutionLegacyUrl,
      );

      if (!mounted) return;
      Navigator.of(context).pop(result);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitError = '$e';
        _submitting = false;
      });
    }
  }

  Future<void> _uploadPdfIfPicked({
    required String? filePath,
    required String kind,
    required String academyId,
    required String fileId,
    required String gradeLabel,
    String? legacyUrl,
  }) async {
    final path = filePath?.trim() ?? '';
    if (path.isEmpty) return;
    final file = File(path);
    if (!await file.exists()) return;
    final bytes = await file.readAsBytes();
    final target = await _pdfService.requestUploadUrl(
      academyId: academyId,
      fileId: fileId,
      gradeLabel: gradeLabel,
      kind: kind,
    );
    await _pdfService.uploadBytes(
      target: target,
      bytes: Uint8List.fromList(bytes),
    );
    final hash = TextbookPdfService.sha256Hex(Uint8List.fromList(bytes));
    await _pdfService.finalizeUpload(
      academyId: academyId,
      fileId: fileId,
      gradeLabel: gradeLabel,
      kind: kind,
      storageDriver: target.storageDriver,
      storageBucket: target.storageBucket,
      storageKey: target.storageKey,
      fileSizeBytes: bytes.length,
      contentHash: hash,
      legacyUrl: legacyUrl,
      migrationStatus: 'dual',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(),
        const Divider(height: 1, color: Color(0xFF2A2A2A)),
        Expanded(child: _buildBody()),
        const Divider(height: 1, color: Color(0xFF2A2A2A)),
        _buildFooter(),
      ],
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      child: Row(
        children: [
          const Icon(Icons.library_add, size: 20, color: Color(0xFF7CC67C)),
          const SizedBox(width: 10),
          const Text(
            '책 추가',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(width: 16),
          _buildStepIndicator(),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.close, color: Color(0xFFB3B3B3)),
            onPressed:
                _submitting ? null : () => Navigator.of(context).pop(null),
          ),
        ],
      ),
    );
  }

  Widget _buildStepIndicator() {
    Widget dot(int i, String label) {
      final active = _step == i;
      final done = _step > i;
      final color = done
          ? const Color(0xFF7CC67C)
          : active
              ? const Color(0xFF7AA9E6)
              : const Color(0xFF3F3F3F);
      return Row(
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              border: Border.all(color: color),
              borderRadius: BorderRadius.circular(11),
            ),
            child: done
                ? const Icon(Icons.check, size: 13, color: Color(0xFF7CC67C))
                : Text(
                    '${i + 1}',
                    style: TextStyle(
                      color: color,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: active ? Colors.white : const Color(0xFF9FB3B3),
              fontSize: 12,
              fontWeight: active ? FontWeight.w800 : FontWeight.w500,
            ),
          ),
        ],
      );
    }

    return Row(
      children: [
        dot(0, '메타·표지'),
        const SizedBox(width: 14),
        dot(1, '파일'),
        const SizedBox(width: 14),
        dot(2, '단원 구조'),
      ],
    );
  }

  Widget _buildBody() {
    switch (_step) {
      case 0:
        return _buildStep1();
      case 1:
        return _buildStep2();
      default:
        return _buildStep3();
    }
  }

  Widget _buildFooter() {
    final primaryLabel = _step < 2 ? '다음' : '완료';
    final primaryEnabled = _step == 0
        ? _canProceedFromStep1
        : _step == 1
            ? true
            : _canFinish && !_submitting;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          if (_submitError != null)
            Expanded(
              child: Text(
                _submitError!,
                style: const TextStyle(
                  color: Color(0xFFE68A8A),
                  fontSize: 12,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            )
          else
            const Spacer(),
          OutlinedButton(
            onPressed: _submitting || _step == 0
                ? null
                : () {
                    setState(() => _step -= 1);
                  },
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFB3B3B3),
              side: const BorderSide(color: Color(0xFF2A2A2A)),
            ),
            child: const Text('이전'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: !primaryEnabled
                ? null
                : () {
                    if (_step < 2) {
                      setState(() => _step += 1);
                    } else {
                      _submit();
                    }
                  },
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF33A373),
            ),
            child: _submitting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Text(primaryLabel),
          ),
        ],
      ),
    );
  }

  Widget _buildStep1() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionTitle('기본 정보'),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 2,
                child: _labeled('시리즈', _buildSeriesDropdown()),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 3,
                child: _labeled('책 이름', _buildTextField(_bookNameCtrl, hint: '예: 쎈 고1')),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _labeled(
            '설명 (선택)',
            _buildTextField(
              _bookDescCtrl,
              hint: '학생앱 책카드 아래에 보이는 짧은 설명',
              maxLines: 3,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 2,
                child: _labeled('과정 라벨', _buildGradeLabelField()),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 2,
                child: _labeled('교재 유형', _buildTextbookTypeDropdown()),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 1,
                child: _labeled('페이지 보정', _buildPageOffsetField()),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildFolderField(),
          const SizedBox(height: 8),
          const Text(
            '선택한 폴더 안에 책카드가 생성됩니다. 선택하지 않으면 최상위(루트)에 저장됩니다.',
            style: TextStyle(color: Color(0xFF8A8A8A), fontSize: 11),
          ),
          const SizedBox(height: 20),
          const _SectionTitle('표지 (선택)'),
          const SizedBox(height: 12),
          _buildCoverPicker(),
          const SizedBox(height: 16),
          if (_series.notes.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF17231F),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF2E7D32)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline,
                      size: 16, color: Color(0xFF7CC67C)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _series.notes,
                      style: const TextStyle(
                        color: Color(0xFFB6D9BE),
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          Text(
            'academy_id: ${_resolvedAcademyId ?? "-"}',
            style: const TextStyle(color: Color(0xFF6A6A6A), fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildStep2() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionTitle('PDF 파일 (선택)'),
          const SizedBox(height: 8),
          const Text(
            '본문·정답·해설 PDF는 모두 선택 사항입니다. 이 단계에서 바로 업로드하거나, '
            '비워둔 뒤 마이그레이션 목록에서 "신규 행 추가"로 나중에 올릴 수 있습니다. '
            'Dropbox 등 기존 링크는 fallback URL로 저장됩니다.',
            style: TextStyle(color: Color(0xFF9FB3B3), fontSize: 12),
          ),
          const SizedBox(height: 14),
          _buildPdfPicker(
            label: '본문 PDF',
            pickedPath: _bodyPdfPath,
            onPick: () => _pickPdf(kind: 'body'),
            onClear: () => setState(() => _bodyPdfPath = null),
          ),
          const SizedBox(height: 10),
          _buildTextField(
            _bodyLegacyCtrl,
            hint: '본문 legacy URL (옵션, 예: Dropbox 링크)',
          ),
          const SizedBox(height: 20),
          _buildPdfPicker(
            label: '정답 PDF',
            pickedPath: _answerPdfPath,
            onPick: () => _pickPdf(kind: 'ans'),
            onClear: () => setState(() => _answerPdfPath = null),
          ),
          const SizedBox(height: 10),
          _buildTextField(
            _answerLegacyCtrl,
            hint: '정답 legacy URL (옵션)',
          ),
          const SizedBox(height: 20),
          _buildPdfPicker(
            label: '해설 PDF',
            pickedPath: _solutionPdfPath,
            onPick: () => _pickPdf(kind: 'sol'),
            onClear: () => setState(() => _solutionPdfPath = null),
          ),
          const SizedBox(height: 10),
          _buildTextField(
            _solutionLegacyCtrl,
            hint: '해설 legacy URL (옵션)',
          ),
        ],
      ),
    );
  }

  Widget _buildStep3() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
          child: Row(
            children: [
              const Expanded(
                child: _SectionTitle('단원 구조'),
              ),
              OutlinedButton.icon(
                onPressed: () => _addBigUnit(),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFB3B3B3),
                  side: const BorderSide(color: Color(0xFF2A2A2A)),
                ),
                icon: const Icon(Icons.add, size: 14),
                label: const Text('대단원 추가'),
              ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            '쎈 교재는 각 중단원이 A 기본다잡기 / B 유형뽀개기 / C 만점도전하기 세 개의 소단원으로 고정됩니다. '
            '소단원별 시작/끝 페이지만 입력하세요.',
            style: TextStyle(color: Color(0xFF9FB3B3), fontSize: 12),
          ),
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF1C2430),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFF2B3A55)),
            ),
            child: const Row(
              children: [
                Icon(Icons.info_outline, size: 14, color: Color(0xFF8AB8E8)),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '신규 등록 교재는 학습앱에 바로 노출되지 않습니다. '
                    '등록 후 "교재 마이그레이션" 화면에서 "학습앱 교재 탭 노출" 스위치를 켜주세요.',
                    style: TextStyle(color: Color(0xFFB0C4DA), fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            itemCount: _bigUnits.length,
            separatorBuilder: (_, __) => const SizedBox(height: 14),
            itemBuilder: (context, index) => _buildBigUnitCard(index),
          ),
        ),
      ],
    );
  }

  Widget _buildBigUnitCard(int index) {
    final unit = _bigUnits[index];
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF15171C),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF222222)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF1B2B1B),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '대단원 ${index + 1}',
                  style: const TextStyle(
                    color: Color(0xFF7CC67C),
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildTextField(unit.nameCtrl, hint: '대단원 이름'),
              ),
              const SizedBox(width: 6),
              IconButton(
                tooltip: '중단원 추가',
                visualDensity: VisualDensity.compact,
                onPressed: () => _addMidUnit(unit),
                icon: const Icon(Icons.add, size: 16, color: Color(0xFF9FB3B3)),
              ),
              IconButton(
                tooltip: '대단원 삭제',
                visualDensity: VisualDensity.compact,
                onPressed: () => _removeBigUnit(index),
                icon: const Icon(Icons.close,
                    size: 16, color: Color(0xFFB3B3B3)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (var m = 0; m < unit.middles.length; m += 1) ...[
            _buildMidUnitRow(unit, m),
            if (m < unit.middles.length - 1) const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }

  Widget _buildMidUnitRow(_BigUnitEdit parent, int midIndex) {
    final mid = parent.middles[midIndex];
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF101216),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF1A1A1A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFF1B2430),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '중단원 ${midIndex + 1}',
                  style: const TextStyle(
                    color: Color(0xFF7AA9E6),
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildTextField(mid.nameCtrl, hint: '중단원 이름'),
              ),
              const SizedBox(width: 6),
              IconButton(
                tooltip: '중단원 삭제',
                visualDensity: VisualDensity.compact,
                onPressed: () => _removeMidUnit(parent, midIndex),
                icon: const Icon(Icons.close,
                    size: 14, color: Color(0xFF9FB3B3)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < mid.subs.length; i += 1) ...[
            _buildSubSectionRow(mid.subs[i]),
            if (i < mid.subs.length - 1) const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }

  Widget _buildSubSectionRow(_SubSectionEdit sub) {
    return Row(
      children: [
        Container(
          width: 120,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1A12),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            sub.preset.displayName,
            style: const TextStyle(
              color: Color(0xFFEAB968),
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _buildTextField(
            sub.startCtrl,
            hint: '시작 페이지',
            keyboardType: TextInputType.number,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
            ],
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _buildTextField(
            sub.endCtrl,
            hint: '끝 페이지',
            keyboardType: TextInputType.number,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSeriesDropdown() {
    return _dropdownContainer(
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _seriesKey,
          dropdownColor: const Color(0xFF15171C),
          isExpanded: true,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          items: [
            for (final entry in kTextbookSeriesCatalog)
              DropdownMenuItem<String>(
                value: entry.key,
                child: Text(entry.displayName),
              ),
          ],
          onChanged: (value) {
            if (value == null) return;
            setState(() {
              _seriesKey = value;
              // Rebuild sub-sections with the new series preset.
              for (final big in _bigUnits) {
                for (final mid in big.middles) {
                  mid.applyPreset(_series);
                }
              }
              if (_textbookType.isEmpty) {
                _textbookType = _series.defaultTextbookType;
              }
            });
          },
        ),
      ),
    );
  }

  Widget _buildGradeLabelField() {
    if (_loadingGrades) {
      return _dropdownContainer(
        child: const Row(
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Color(0xFF9FB3B3),
              ),
            ),
            SizedBox(width: 8),
            Text('과정 로드 중...',
                style: TextStyle(color: Color(0xFFB3B3B3), fontSize: 12)),
          ],
        ),
      );
    }
    if (_gradeOptions.isEmpty) {
      return _buildTextField(_gradeLabelCtrl, hint: '예: 고1');
    }
    return _dropdownContainer(
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _gradeOptions.contains(_gradeLabelCtrl.text.trim())
              ? _gradeLabelCtrl.text.trim()
              : _gradeOptions.first,
          dropdownColor: const Color(0xFF15171C),
          isExpanded: true,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          items: [
            for (final g in _gradeOptions)
              DropdownMenuItem<String>(value: g, child: Text(g)),
          ],
          onChanged: (value) {
            if (value == null) return;
            setState(() => _gradeLabelCtrl.text = value);
          },
        ),
      ),
    );
  }

  Widget _buildTextbookTypeDropdown() {
    return _dropdownContainer(
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _textbookType,
          dropdownColor: const Color(0xFF15171C),
          isExpanded: true,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          items: const [
            DropdownMenuItem(value: '개념서', child: Text('개념서')),
            DropdownMenuItem(value: '문제집', child: Text('문제집')),
          ],
          onChanged: (value) {
            if (value == null) return;
            setState(() => _textbookType = value);
          },
        ),
      ),
    );
  }

  Widget _buildFolderField() {
    // Same visual language as `_labeled`, but with a trailing "+ 새 폴더"
    // button so the operator can seed a new textbook folder (name + 설명)
    // without leaving the wizard.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              '교재 폴더',
              style: TextStyle(
                color: Color(0xFFB3B3B3),
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.3,
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: _loadingFolders ? null : _openNewFolderDialog,
              icon: const Icon(Icons.create_new_folder_outlined,
                  size: 14, color: Color(0xFF9FD49F)),
              label: const Text(
                '새 폴더',
                style: TextStyle(
                  color: Color(0xFF9FD49F),
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                minimumSize: const Size(0, 22),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        _buildFolderDropdown(),
      ],
    );
  }

  Future<void> _openNewFolderDialog() async {
    final parentId = _selectedFolderId == _rootFolderValue
        ? null
        : _selectedFolderId;
    final parentName = parentId == null
        ? null
        : _folderOptions
            .firstWhere(
              (f) => f.id == parentId,
              orElse: () => const _ResourceFolderOption(
                id: '', name: '', depth: 0),
            )
            .name;
    final result = await showDialog<_NewFolderResult>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _NewFolderDialog(
        parentName: (parentName ?? '').isEmpty ? null : parentName,
      ),
    );
    if (result == null) return;
    await _createFolder(
      name: result.name,
      description: result.description,
      parentId: parentId,
    );
  }

  Future<void> _createFolder({
    required String name,
    required String description,
    required String? parentId,
  }) async {
    final academyId = (_resolvedAcademyId ?? '').trim();
    if (academyId.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('학원 정보를 확인할 수 없어 폴더를 만들 수 없습니다.')),
      );
      return;
    }
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) return;
    final id = const Uuid().v4();
    int nextOrderIndex = 0;
    try {
      final builder = _supabase
          .from('resource_folders')
          .select('order_index')
          .eq('academy_id', academyId);
      final dynamic siblings = parentId == null
          ? await builder.isFilter('parent_id', null)
          : await builder.eq('parent_id', parentId);
      if (siblings is List) {
        int maxIdx = -1;
        for (final row in siblings) {
          if (row is Map && row['order_index'] is num) {
            final v = (row['order_index'] as num).toInt();
            if (v > maxIdx) maxIdx = v;
          }
        }
        nextOrderIndex = maxIdx + 1;
      }
    } catch (_) {
      nextOrderIndex = 0;
    }

    final payload = <String, Object?>{
      'id': id,
      'academy_id': academyId,
      'name': trimmedName,
      'description': description.trim().isEmpty ? null : description.trim(),
      'parent_id': parentId,
      'category': 'textbook',
      'order_index': nextOrderIndex,
    };
    try {
      await _supabase.from('resource_folders').insert(payload);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('폴더 생성 실패: $e')),
      );
      return;
    }
    await _loadFolderOptions();
    if (!mounted) return;
    setState(() {
      _selectedFolderId = id;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('새 폴더 "$trimmedName" 을 만들었어요.')),
    );
  }

  Widget _buildFolderDropdown() {
    if (_loadingFolders) {
      return _dropdownContainer(
        child: const Row(
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Color(0xFF9FB3B3),
              ),
            ),
            SizedBox(width: 8),
            Text('교재 폴더 로드 중...',
                style: TextStyle(color: Color(0xFFB3B3B3), fontSize: 12)),
          ],
        ),
      );
    }
    final items = <DropdownMenuItem<String>>[
      const DropdownMenuItem<String>(
        value: _rootFolderValue,
        child: Text('최상위 (루트)'),
      ),
      for (final folder in _folderOptions)
        DropdownMenuItem<String>(
          value: folder.id,
          child: Text(folder.displayName),
        ),
    ];
    final value = items.any((item) => item.value == _selectedFolderId)
        ? _selectedFolderId
        : _rootFolderValue;
    return _dropdownContainer(
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          dropdownColor: const Color(0xFF15171C),
          isExpanded: true,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          items: items,
          onChanged: (next) {
            if (next == null) return;
            setState(() => _selectedFolderId = next);
          },
        ),
      ),
    );
  }

  Widget _buildPageOffsetField() {
    return _buildTextField(
      _pageOffsetCtrl,
      hint: '0',
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'^-?\d*$')),
      ],
    );
  }

  Widget _buildCoverPicker() {
    final hasLocal = (_coverLocalPath ?? '').isNotEmpty;
    final hasRemote = (_coverExistingUrl ?? '').isNotEmpty;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF15171C),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF222222)),
      ),
      child: Row(
        children: [
          Container(
            width: 80,
            height: 110,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFF0E1013),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFF2A2A2A)),
            ),
            child: hasLocal
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(5),
                    child: Image.file(
                      File(_coverLocalPath!),
                      fit: BoxFit.cover,
                      width: 80,
                      height: 110,
                    ),
                  )
                : hasRemote
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(5),
                        child: Image.network(
                          _coverExistingUrl!,
                          fit: BoxFit.cover,
                          width: 80,
                          height: 110,
                          errorBuilder: (_, __, ___) =>
                              const Icon(Icons.image_not_supported,
                                  color: Color(0xFF4A4A4A)),
                        ),
                      )
                    : const Icon(Icons.image_outlined,
                        color: Color(0xFF4A4A4A), size: 28),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  hasLocal
                      ? p.basename(_coverLocalPath!)
                      : (hasRemote ? _coverExistingUrl! : '표지가 없습니다'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFD8E0E0),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _pickCover,
                      icon: const Icon(Icons.folder_open,
                          size: 14, color: Color(0xFFB3B3B3)),
                      label: const Text(
                        '이미지 선택',
                        style: TextStyle(
                          color: Color(0xFFB3B3B3),
                          fontSize: 12,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFF2A2A2A)),
                      ),
                    ),
                    if (hasLocal || hasRemote) ...[
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: () => setState(() {
                          _coverLocalPath = null;
                          _coverExistingUrl = null;
                        }),
                        icon: const Icon(Icons.clear,
                            size: 14, color: Color(0xFFE68A8A)),
                        label: const Text(
                          '제거',
                          style: TextStyle(
                            color: Color(0xFFE68A8A),
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPdfPicker({
    required String label,
    required String? pickedPath,
    required VoidCallback onPick,
    required VoidCallback onClear,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF15171C),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF222222)),
      ),
      child: Row(
        children: [
          const Icon(Icons.picture_as_pdf_outlined,
              size: 18, color: Color(0xFFE68A8A)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  (pickedPath == null || pickedPath.isEmpty)
                      ? '파일이 선택되지 않았습니다'
                      : p.basename(pickedPath),
                  style: const TextStyle(
                    color: Color(0xFF9FB3B3),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: onPick,
            icon: const Icon(Icons.file_upload_outlined,
                size: 14, color: Color(0xFFB3B3B3)),
            label: const Text(
              '선택',
              style: TextStyle(color: Color(0xFFB3B3B3), fontSize: 12),
            ),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Color(0xFF2A2A2A)),
            ),
          ),
          if (pickedPath != null && pickedPath.isNotEmpty) ...[
            const SizedBox(width: 6),
            TextButton(
              onPressed: onClear,
              child: const Text('제거',
                  style: TextStyle(color: Color(0xFFE68A8A), fontSize: 12)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTextField(
    TextEditingController controller, {
    required String hint,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    int maxLines = 1,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      maxLines: maxLines,
      style: const TextStyle(color: Colors.white, fontSize: 13),
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Color(0xFF6A6A6A), fontSize: 12),
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        filled: true,
        fillColor: const Color(0xFF15171C),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: Color(0xFF2A2A2A)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: Color(0xFF33A373)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: Color(0xFF2A2A2A)),
        ),
      ),
    );
  }

  Widget _labeled(String label, Widget child) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFFB3B3B3),
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(height: 6),
        child,
      ],
    );
  }

  Widget _dropdownContainer({required Widget child}) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF15171C),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      alignment: Alignment.centerLeft,
      child: child,
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 14,
        fontWeight: FontWeight.w800,
      ),
    );
  }
}

class _ResourceFolderOption {
  const _ResourceFolderOption({
    required this.id,
    required this.name,
    required this.depth,
  });

  final String id;
  final String name;
  final int depth;

  String get displayName {
    if (depth <= 0) return name;
    return '${'  ' * depth}$name';
  }
}

class _BigUnitEdit {
  final TextEditingController nameCtrl = TextEditingController();
  final List<_MidUnitEdit> middles = <_MidUnitEdit>[];

  void dispose() {
    nameCtrl.dispose();
    for (final m in middles) {
      m.dispose();
    }
  }
}

class _MidUnitEdit {
  _MidUnitEdit({required TextbookSeriesCatalogEntry series}) {
    applyPreset(series);
  }

  final TextEditingController nameCtrl = TextEditingController();
  final List<_SubSectionEdit> subs = <_SubSectionEdit>[];

  void applyPreset(TextbookSeriesCatalogEntry series) {
    // Preserve whatever numbers the user already typed when switching series.
    final keyed = <String, _SubSectionEdit>{
      for (final s in subs) s.preset.key: s,
    };
    final rebuilt = <_SubSectionEdit>[];
    for (final preset in series.subPreset) {
      final existing = keyed.remove(preset.key);
      if (existing != null) {
        rebuilt.add(existing.withPreset(preset));
      } else {
        rebuilt.add(_SubSectionEdit(preset: preset));
      }
    }
    // Dispose any subs that don't map to the new preset.
    for (final leftover in keyed.values) {
      leftover.dispose();
    }
    subs
      ..clear()
      ..addAll(rebuilt);
  }

  void dispose() {
    nameCtrl.dispose();
    for (final s in subs) {
      s.dispose();
    }
  }
}

class _SubSectionEdit {
  _SubSectionEdit({required this.preset});
  TextbookSubSectionPreset preset;
  final TextEditingController startCtrl = TextEditingController();
  final TextEditingController endCtrl = TextEditingController();

  _SubSectionEdit withPreset(TextbookSubSectionPreset next) {
    preset = next;
    return this;
  }

  void dispose() {
    startCtrl.dispose();
    endCtrl.dispose();
  }
}

int? _positiveInt(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return null;
  final n = int.tryParse(t);
  if (n == null || n <= 0) return null;
  return n;
}

// ─────────── New folder dialog (name + 설명) ───────────

class _NewFolderResult {
  const _NewFolderResult({required this.name, required this.description});
  final String name;
  final String description;
}

class _NewFolderDialog extends StatefulWidget {
  const _NewFolderDialog({this.parentName});

  /// When non-null, the new folder will be created under this folder.
  final String? parentName;

  @override
  State<_NewFolderDialog> createState() => _NewFolderDialogState();
}

class _NewFolderDialogState extends State<_NewFolderDialog> {
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('폴더 이름을 입력하세요.')),
      );
      return;
    }
    Navigator.of(context).pop(
      _NewFolderResult(name: name, description: _descCtrl.text),
    );
  }

  @override
  Widget build(BuildContext context) {
    final parent = widget.parentName;
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('새 교재 폴더',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (parent != null && parent.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  '상위 폴더: $parent',
                  style: const TextStyle(
                      color: Color(0xFFB3B3B3),
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
                ),
              ),
            TextField(
              controller: _nameCtrl,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: '폴더명',
                labelStyle: TextStyle(color: Colors.white70),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.white24),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF1976D2)),
                ),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _descCtrl,
              style: const TextStyle(color: Colors.white),
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '설명 (선택)',
                labelStyle: TextStyle(color: Colors.white70),
                hintText: '이 폴더에 어떤 교재가 들어가는지 간단히',
                hintStyle: TextStyle(color: Colors.white38),
                alignLabelWithHint: true,
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.white24),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF1976D2)),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child:
              const Text('취소', style: TextStyle(color: Colors.white70)),
        ),
        FilledButton(
          onPressed: _save,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF33A373),
          ),
          child: const Text('만들기'),
        ),
      ],
    );
  }
}
