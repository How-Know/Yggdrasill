import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/textbook_book_registry.dart';
import '../../services/textbook_pdf_service.dart';
import '../../widgets/latex_text_renderer.dart';
import 'textbook_crop_extract_dialog.dart';
import 'textbook_register_wizard.dart';
import 'textbook_unit_authoring_dialog.dart';
import 'textbook_vlm_test_dialog.dart';

/// Phase-1 migration pane for the textbook tab.
///
/// This screen is intentionally isolated from the legacy [TextbookScreen]
/// state. It loads its own book list and `resource_file_links` rows so we
/// can test the Dropbox → Supabase Storage flow without mutating the
/// existing management UI. When the migration is promoted to default, this
/// file can be deleted along with the mode switch in `TextbookScreen`.
///
/// Responsibilities:
/// 1. List every `resource_files` row that is categorised as a textbook.
/// 2. On selection, read every `resource_file_links` row (all grades, all
///    kinds) for that book and render a status table.
/// 3. Per row: show migration badge, allow picking a local PDF, upload it
///    to Supabase Storage via the gateway, and toggle `migration_status`
///    between `dual` ↔ `migrated` ↔ `legacy`.
class TextbookMigrationPane extends StatefulWidget {
  const TextbookMigrationPane({super.key});

  @override
  State<TextbookMigrationPane> createState() => _TextbookMigrationPaneState();
}

class _TextbookMigrationPaneState extends State<TextbookMigrationPane> {
  final _supabase = Supabase.instance.client;
  final _service = TextbookPdfService();
  final _registry = TextbookBookRegistry();

  bool _loadingBooks = false;
  bool _loadingLinks = false;
  String? _bookError;
  String? _linkError;

  List<_MigBook> _books = [];
  String? _selectedBookId;
  List<_MigLink> _links = [];

  // Tracks rows currently busy (upload or status update) so we can disable
  // their action buttons and show a spinner.
  final Set<String> _busy = <String>{};

  @override
  void initState() {
    super.initState();
    _loadBooks();
  }

  @override
  void dispose() {
    super.dispose();
  }

  // ---------------- data loading ----------------

  Future<void> _loadBooks() async {
    setState(() {
      _loadingBooks = true;
      _bookError = null;
    });
    try {
      List<Map<String, dynamic>> rows;
      try {
        final data = await _supabase
            .from('resource_files')
            .select('id,name,category,order_index,academy_id,is_published')
            .order('order_index')
            .order('name');
        rows = (data as List).cast<Map<String, dynamic>>();
      } catch (e) {
        // Graceful fallback if the `is_published` migration has not been
        // applied yet (e.g. developer running against an older DB). We
        // treat unknown books as `published=true` so nothing disappears.
        final data = await _supabase
            .from('resource_files')
            .select('id,name,category,order_index,academy_id')
            .order('order_index')
            .order('name');
        rows = (data as List).cast<Map<String, dynamic>>();
      }
      final books = rows.where((r) {
        final rawCategory = r['category'];
        final category =
            rawCategory is String ? rawCategory.trim().toLowerCase() : '';
        return category.isEmpty || category == 'textbook';
      }).map((r) {
        final rawPub = r['is_published'];
        final pub = rawPub is bool ? rawPub : true;
        return _MigBook(
          id: r['id'] as String,
          academyId: r['academy_id'] as String?,
          name: (r['name'] as String?)?.trim() ?? '(이름 없음)',
          orderIndex: r['order_index'] as int?,
          isPublished: pub,
        );
      }).toList();
      books.sort((a, b) {
        final ai = a.orderIndex ?? 1 << 30;
        final bi = b.orderIndex ?? 1 << 30;
        final t = ai.compareTo(bi);
        if (t != 0) return t;
        return a.name.compareTo(b.name);
      });
      if (!mounted) return;
      setState(() {
        _books = books;
        _loadingBooks = false;
        if (_selectedBookId != null &&
            books.every((b) => b.id != _selectedBookId)) {
          _selectedBookId = null;
          _links = [];
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingBooks = false;
        _bookError = '$e';
      });
    }
  }

  Future<void> _loadLinks(String bookId) async {
    setState(() {
      _loadingLinks = true;
      _linkError = null;
      _links = [];
    });
    try {
      final data = await _supabase
          .from('resource_file_links')
          .select(
            'id,academy_id,file_id,grade,url,storage_driver,storage_bucket,storage_key,migration_status,file_size_bytes,content_hash,uploaded_at',
          )
          .eq('file_id', bookId);
      final rows = (data as List).cast<Map<String, dynamic>>();
      final parsed = <_MigLink>[];
      for (final r in rows) {
        final rawGrade = (r['grade'] as String?)?.trim() ?? '';
        if (rawGrade.isEmpty) continue;
        final parts = rawGrade.split('#');
        final gradeLabel = parts.isNotEmpty ? parts.first.trim() : '';
        final kind =
            (parts.length > 1 ? parts[1] : 'body').trim().toLowerCase();
        if (gradeLabel.isEmpty || !_kinds.contains(kind)) continue;
        parsed.add(_MigLink(
          id: (r['id'] as num?)?.toInt() ?? 0,
          academyId: (r['academy_id'] as String?)?.trim() ?? '',
          fileId: (r['file_id'] as String?)?.trim() ?? '',
          gradeLabel: gradeLabel,
          kind: kind,
          url: (r['url'] as String?)?.trim() ?? '',
          storageDriver: (r['storage_driver'] as String?)?.trim() ?? '',
          storageBucket: (r['storage_bucket'] as String?)?.trim() ?? '',
          storageKey: (r['storage_key'] as String?)?.trim() ?? '',
          migrationStatus:
              (r['migration_status'] as String?)?.trim() ?? 'legacy',
          fileSizeBytes: (r['file_size_bytes'] as num?)?.toInt() ?? 0,
          contentHash: (r['content_hash'] as String?)?.trim() ?? '',
          uploadedAt: (r['uploaded_at'] as String?)?.trim() ?? '',
        ));
      }
      parsed.sort((a, b) {
        final g = a.gradeLabel.compareTo(b.gradeLabel);
        if (g != 0) return g;
        return _kindOrder(a.kind).compareTo(_kindOrder(b.kind));
      });
      if (!mounted) return;
      setState(() {
        _links = parsed;
        _loadingLinks = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingLinks = false;
        _linkError = '$e';
      });
    }
  }

  // ---------------- upload + status helpers ----------------

  Future<void> _pickAndUpload(
    _MigLink? existing, {
    String? gradeOverride,
    String? kindOverride,
  }) async {
    final book = _selectedBook;
    if (book == null) {
      _toast('교재를 먼저 선택하세요', error: true);
      return;
    }
    final academyId = book.academyId;
    if (academyId == null || academyId.isEmpty) {
      _toast('이 교재에 academy_id가 설정되어 있지 않습니다', error: true);
      return;
    }
    final gradeLabel = existing?.gradeLabel ?? gradeOverride ?? '';
    final kind = existing?.kind ?? kindOverride ?? 'body';
    if (gradeLabel.isEmpty) {
      _toast('학년 라벨이 비어있습니다', error: true);
      return;
    }
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: '교재 PDF 선택 ($gradeLabel · ${_kindLabel(kind)})',
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
      withData: false,
    );
    if (picked == null || picked.files.isEmpty) return;
    final file = picked.files.first;
    final path = file.path;
    if (path == null || path.isEmpty) {
      _toast('파일 경로를 읽을 수 없습니다', error: true);
      return;
    }
    final busyKey = '${existing?.id ?? 'new'}|$gradeLabel|$kind';
    setState(() => _busy.add(busyKey));
    try {
      final bytes = await File(path).readAsBytes();
      final target = await _service.requestUploadUrl(
        academyId: academyId,
        fileId: book.id,
        gradeLabel: gradeLabel,
        kind: kind,
      );
      await _service.uploadBytes(
        target: target,
        bytes: Uint8List.fromList(bytes),
      );
      final hash = TextbookPdfService.sha256Hex(Uint8List.fromList(bytes));
      await _service.finalizeUpload(
        linkId: existing?.id == 0 ? null : existing?.id,
        academyId: academyId,
        fileId: book.id,
        gradeLabel: gradeLabel,
        kind: kind,
        storageDriver: target.storageDriver,
        storageBucket: target.storageBucket,
        storageKey: target.storageKey,
        fileSizeBytes: bytes.length,
        contentHash: hash,
        legacyUrl: existing?.url,
        migrationStatus: 'dual',
      );
      if (!mounted) return;
      _toast(
        '${_kindLabel(kind)} 업로드 완료 (${_fmtSize(bytes.length)}) · dual 상태로 전환',
      );
      await _loadLinks(book.id);
    } catch (e) {
      _toast('업로드 실패: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(busyKey));
    }
  }

  Future<void> _setStatus(_MigLink link, String nextStatus) async {
    if (link.id == 0) {
      _toast('링크 ID가 없어 상태를 변경할 수 없습니다', error: true);
      return;
    }
    final busyKey = '${link.id}|${link.gradeLabel}|${link.kind}';
    setState(() => _busy.add(busyKey));
    try {
      await _service.setMigrationStatus(
        linkId: link.id,
        migrationStatus: nextStatus,
      );
      if (_selectedBookId != null) {
        await _loadLinks(_selectedBookId!);
      }
      if (!mounted) return;
      _toast('상태를 $nextStatus 로 변경했습니다');
    } catch (e) {
      _toast('상태 변경 실패: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(busyKey));
    }
  }

  void _toast(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor:
            error ? const Color(0xFFB53A3A) : const Color(0xFF2E7D32),
      ),
    );
  }

  // ---------------- layout ----------------

  _MigBook? get _selectedBook {
    if (_selectedBookId == null) return null;
    for (final b in _books) {
      if (b.id == _selectedBookId) return b;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(),
          const SizedBox(height: 16),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 260,
                  child: _buildBookList(),
                ),
                const SizedBox(width: 16),
                Expanded(child: _buildDetail()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '교재 마이그레이션 (Phase 1 · 테스트용)',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                ),
              ),
              SizedBox(height: 6),
              Text(
                'Dropbox URL을 유지한 채 Supabase Storage로 병행 업로드합니다. 행 단위 legacy → dual → migrated 순으로 전환하고, 문제 발생 시 한 줄 SQL 또는 상단 버튼으로 즉시 롤백할 수 있습니다.',
                style: TextStyle(color: Color(0xFF9FB3B3), fontSize: 13),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        FilledButton.icon(
          onPressed: _openAddBookWizard,
          icon: const Icon(Icons.library_add, size: 16, color: Colors.white),
          label: const Text(
            '책 추가',
            style: TextStyle(color: Colors.white, fontSize: 12),
          ),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF33A373),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: _loadBooks,
          icon: const Icon(Icons.refresh, size: 16, color: Color(0xFFB3B3B3)),
          label: const Text(
            '교재 목록 새로고침',
            style: TextStyle(color: Color(0xFFB3B3B3), fontSize: 12),
          ),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: Color(0xFF2A2A2A)),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
        ),
      ],
    );
  }

  Future<void> _openAddBookWizard() async {
    final defaultAcademyId = _selectedBook?.academyId ??
        (_books.isNotEmpty ? _books.first.academyId : null);
    final result = await TextbookRegisterWizard.show(
      context,
      defaultAcademyId: defaultAcademyId,
    );
    if (!mounted || result == null) return;
    _toast('신규 교재 "${result.bookId}"를 등록했습니다');
    await _loadBooks();
    setState(() => _selectedBookId = result.bookId);
    await _loadLinks(result.bookId);
  }

  void _openUnitAuthoring(_MigLink link) {
    final book = _resolveBookForLink(link);
    TextbookUnitAuthoringDialog.show(
      context,
      academyId: link.academyId,
      bookId: link.fileId,
      bookName: book.name,
      gradeLabel: link.gradeLabel,
      linkId: link.id == 0 ? null : link.id,
    );
  }

  Widget _buildBookList() {
    if (_loadingBooks) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Color(0xFF33A373),
          ),
        ),
      );
    }
    if (_bookError != null) {
      return _buildErrorBox(_bookError!, onRetry: _loadBooks);
    }
    if (_books.isEmpty) {
      return _buildEmptyBox('등록된 교재가 없습니다');
    }
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF131315),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 12, 14, 6),
            child: Text(
              '교재 목록',
              style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const Divider(height: 1, color: Color(0xFF2A2A2A)),
          Expanded(
            child: ListView.builder(
              itemCount: _books.length,
              itemBuilder: (context, index) {
                final b = _books[index];
                final selected = b.id == _selectedBookId;
                return InkWell(
                  onTap: () {
                    setState(() => _selectedBookId = b.id);
                    _loadLinks(b.id);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    color:
                        selected ? const Color(0xFF1B2B1B) : Colors.transparent,
                    child: Row(
                      children: [
                        Icon(
                          selected
                              ? Icons.radio_button_checked
                              : Icons.menu_book_outlined,
                          size: 16,
                          color: selected
                              ? const Color(0xFF7CC67C)
                              : const Color(0xFF9FB3B3),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: LatexTextRenderer(
                            b.name,
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: selected
                                  ? Colors.white
                                  : const Color(0xFFD8E0E0),
                              fontSize: 13,
                              fontWeight:
                                  selected ? FontWeight.w800 : FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetail() {
    final book = _selectedBook;
    if (book == null) {
      return _buildEmptyBox('왼쪽에서 교재를 선택하세요');
    }
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF131315),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: LatexTextRenderer(
                  book.name,
                  maxLines: 2,
                  softWrap: true,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'academy_id: ${book.academyId ?? "-"}',
                style: const TextStyle(color: Color(0xFF8A8A8A), fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'file_id: ${book.id}',
            style: const TextStyle(color: Color(0xFF8A8A8A), fontSize: 11),
          ),
          const SizedBox(height: 12),
          _buildBookControlBar(book),
          const SizedBox(height: 14),
          const Divider(height: 1, color: Color(0xFF2A2A2A)),
          const SizedBox(height: 10),
          Expanded(child: _buildLinksTable()),
        ],
      ),
    );
  }

  Widget _buildBookControlBar(_MigBook book) {
    final busyKey = 'book_ctrl:${book.id}';
    final busy = _busy.contains(busyKey);
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF181818),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Icon(
            book.isPublished ? Icons.public : Icons.public_off,
            size: 16,
            color: book.isPublished
                ? const Color(0xFF7CC67C)
                : const Color(0xFF9FB3B3),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '학습앱 교재 탭 노출',
                  style: TextStyle(
                    color: book.isPublished
                        ? Colors.white
                        : const Color(0xFFD8E0E0),
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  book.isPublished
                      ? '학생이 교재 탭에서 이 책을 열람할 수 있습니다.'
                      : '스위치를 켜야 학생 교재 탭에 책카드가 노출됩니다.',
                  style: const TextStyle(
                    color: Color(0xFF8A8A8A),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch.adaptive(
            value: book.isPublished,
            activeThumbColor: const Color(0xFF7CC67C),
            onChanged: busy ? null : (v) => _togglePublished(book, v),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: busy ? null : () => _confirmDeleteBook(book),
            icon: const Icon(Icons.delete_outline,
                size: 16, color: Color(0xFFE46A6A)),
            label: const Text(
              '책 삭제',
              style: TextStyle(color: Color(0xFFE46A6A), fontSize: 12),
            ),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Color(0xFF5A2323)),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _togglePublished(_MigBook book, bool next) async {
    final busyKey = 'book_ctrl:${book.id}';
    setState(() => _busy.add(busyKey));
    try {
      await _registry.setBookPublished(
        bookId: book.id,
        isPublished: next,
      );
      final updated = _MigBook(
        id: book.id,
        name: book.name,
        academyId: book.academyId,
        orderIndex: book.orderIndex,
        isPublished: next,
      );
      if (!mounted) return;
      setState(() {
        for (var i = 0; i < _books.length; i += 1) {
          if (_books[i].id == book.id) {
            _books[i] = updated;
            break;
          }
        }
      });
      _toast(next ? '학습앱 노출을 켰습니다' : '학습앱 노출을 껐습니다');
    } catch (e) {
      _toast('노출 상태 변경 실패: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(busyKey));
    }
  }

  Future<void> _confirmDeleteBook(_MigBook book) async {
    final academyId = (book.academyId ?? '').trim();
    if (academyId.isEmpty) {
      _toast('academy_id가 없어 삭제할 수 없습니다', error: true);
      return;
    }
    final typedName = TextEditingController();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1B1B1D),
          title: const Text(
            '교재 삭제',
            style: TextStyle(color: Colors.white),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '"${book.name}" 교재의 PDF·표지·크롭 이미지·단원 메타데이터를\n모두 영구 삭제합니다. 되돌릴 수 없습니다.',
                style: const TextStyle(color: Color(0xFFD8E0E0), fontSize: 13),
              ),
              const SizedBox(height: 10),
              const Text(
                '확인을 위해 아래에 교재 이름을 그대로 입력하세요.',
                style: TextStyle(color: Color(0xFF9FB3B3), fontSize: 11),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: typedName,
                autofocus: true,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: book.name,
                  hintStyle: const TextStyle(color: Color(0xFF5A5A5A)),
                  filled: true,
                  fillColor: const Color(0xFF232323),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFF2A2A2A)),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () {
                final entered = typedName.text.trim();
                if (entered != book.name.trim()) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(
                      content: Text('이름이 일치하지 않습니다'),
                      backgroundColor: Color(0xFFB53A3A),
                    ),
                  );
                  return;
                }
                Navigator.of(ctx).pop(true);
              },
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFB53A3A),
              ),
              child: const Text('영구 삭제'),
            ),
          ],
        );
      },
    );
    if (confirm != true) return;

    final busyKey = 'book_ctrl:${book.id}';
    setState(() => _busy.add(busyKey));
    try {
      final result = await _service.deleteBook(
        academyId: academyId,
        bookId: book.id,
      );
      if (!mounted) return;
      final removed =
          result.removedCrops + result.removedPdfs + result.removedCovers;
      _toast(
        '교재 삭제 완료 (PDF ${result.removedPdfs}, 크롭 ${result.removedCrops}, 표지 ${result.removedCovers}, 총 $removed개)',
      );
      setState(() {
        _books.removeWhere((b) => b.id == book.id);
        if (_selectedBookId == book.id) {
          _selectedBookId = null;
          _links = [];
        }
      });
      if (result.warnings.isNotEmpty) {
        // Non-fatal Storage cleanup warnings — log but keep the row removed.
        // ignore: avoid_print
        print('[pane][delete] warnings: ${result.warnings}');
      }
    } catch (e) {
      if (!mounted) return;
      _toast('교재 삭제 실패: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(busyKey));
    }
  }

  Widget _buildLinksTable() {
    if (_loadingLinks) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Color(0xFF33A373),
          ),
        ),
      );
    }
    if (_linkError != null) {
      return _buildErrorBox(_linkError!,
          onRetry: () =>
              _selectedBookId == null ? null : _loadLinks(_selectedBookId!));
    }
    if (_links.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '이 교재에 등록된 PDF 링크가 아직 없습니다.',
            style: TextStyle(color: Color(0xFFB3B3B3), fontSize: 13),
          ),
          const SizedBox(height: 12),
          const Text(
            '학년/종류를 지정한 신규 행을 바로 업로드할 수 있습니다.',
            style: TextStyle(color: Color(0xFF8A8A8A), fontSize: 12),
          ),
          const SizedBox(height: 12),
          _buildNewRowPicker(),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildTableHeader(),
        const SizedBox(height: 6),
        Expanded(
          child: ListView.separated(
            itemCount: _links.length,
            separatorBuilder: (_, __) => const SizedBox(height: 6),
            itemBuilder: (context, index) => _buildLinkRow(_links[index]),
          ),
        ),
        const SizedBox(height: 10),
        const Divider(height: 1, color: Color(0xFF2A2A2A)),
        const SizedBox(height: 10),
        const Text(
          '신규 행 추가 업로드',
          style: TextStyle(
              color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        _buildNewRowPicker(),
      ],
    );
  }

  Widget _buildTableHeader() {
    const style = TextStyle(
      color: Color(0xFF8A8A8A),
      fontSize: 11,
      fontWeight: FontWeight.w800,
      letterSpacing: 0.3,
    );
    return Row(
      children: const [
        SizedBox(width: 64, child: Text('학년', style: style)),
        SizedBox(width: 52, child: Text('종류', style: style)),
        SizedBox(width: 84, child: Text('상태', style: style)),
        Expanded(child: Text('파일', style: style)),
        SizedBox(width: 72, child: Text('크기', style: style)),
        SizedBox(width: 390, child: Text('조작', style: style)),
      ],
    );
  }

  Widget _buildLinkRow(_MigLink link) {
    final busyKey = '${link.id}|${link.gradeLabel}|${link.kind}';
    final isBusy = _busy.contains(busyKey);
    final hasLegacy = link.url.isNotEmpty;
    final hasStorage = link.storageKey.isNotEmpty;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF15171C),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF222222)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              link.gradeLabel,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          SizedBox(
            width: 52,
            child: Text(
              _kindLabel(link.kind),
              style: const TextStyle(
                color: Color(0xFFB3B3B3),
                fontSize: 12,
              ),
            ),
          ),
          SizedBox(
              width: 84,
              child: _StatusBadge(
                  status:
                      hasLegacy || hasStorage ? link.migrationStatus : 'none')),
          Expanded(
            child: Text(
              hasStorage ? link.storageKey : link.url,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF9FB3B3),
                fontSize: 12,
              ),
            ),
          ),
          SizedBox(
            width: 72,
            child: Text(
              _fmtSize(link.fileSizeBytes),
              style: const TextStyle(color: Color(0xFF9FB3B3), fontSize: 12),
            ),
          ),
          SizedBox(
            width: 390,
            child: isBusy
                ? const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF33A373),
                        ),
                      ),
                      SizedBox(width: 8),
                      Text('처리 중...',
                          style: TextStyle(
                              color: Color(0xFF9FB3B3), fontSize: 12)),
                    ],
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: _buildRowActions(link),
                  ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildRowActions(_MigLink link) {
    final widgets = <Widget>[];
    widgets.add(_ActionButton(
      icon: Icons.upload_file,
      label: '업로드',
      onPressed: () => _pickAndUpload(link),
    ));
    if (link.id != 0) {
      if (link.migrationStatus == 'dual') {
        widgets.add(const SizedBox(width: 6));
        widgets.add(_ActionButton(
          icon: Icons.verified,
          label: 'Migrated',
          onPressed: () => _setStatus(link, 'migrated'),
        ));
      }
      if (link.migrationStatus != 'legacy' && link.url.isNotEmpty) {
        widgets.add(const SizedBox(width: 6));
        widgets.add(_ActionButton(
          icon: Icons.undo,
          label: 'Legacy로',
          onPressed: () => _setStatus(link, 'legacy'),
          danger: true,
        ));
      }
      if (link.kind == 'body' &&
          (link.storageKey.isNotEmpty || link.url.isNotEmpty)) {
        widgets.add(const SizedBox(width: 6));
        widgets.add(_ActionButton(
          icon: Icons.account_tree_outlined,
          label: '단원·분석',
          onPressed: () => _openUnitAuthoring(link),
        ));
      }
    }
    return widgets;
  }

  _MigBook _resolveBookForLink(_MigLink link) {
    return _books.firstWhere(
      (b) => b.id == link.fileId,
      orElse: () => _MigBook(
        id: link.fileId,
        name: link.fileId,
        academyId: link.academyId,
        orderIndex: null,
        isPublished: true,
      ),
    );
  }

  // Kept as an internal maintenance hook; the main list no longer exposes it.
  // ignore: unused_element
  void _openVlmTestDialog(_MigLink link) {
    final book = _resolveBookForLink(link);
    TextbookVlmTestDialog.show(
      context,
      linkId: link.id,
      academyId: link.academyId,
      bookId: link.fileId,
      bookName: book.name,
      gradeLabel: link.gradeLabel,
      kind: link.kind,
    );
  }

  // Kept as an internal maintenance hook; the main list no longer exposes it.
  // ignore: unused_element
  void _openCropExtractDialog(_MigLink link) {
    final book = _resolveBookForLink(link);
    TextbookCropExtractDialog.show(
      context,
      linkId: link.id,
      academyId: link.academyId,
      bookId: link.fileId,
      bookName: book.name,
      gradeLabel: link.gradeLabel,
      kind: link.kind,
    );
  }

  Widget _buildNewRowPicker() {
    return _NewRowPicker(
      onSubmit: (grade, kind) {
        _pickAndUpload(null, gradeOverride: grade, kindOverride: kind);
      },
    );
  }

  Widget _buildErrorBox(String error, {VoidCallback? onRetry}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF2A1919),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF5A2A2A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '로드 실패',
            style: TextStyle(
              color: Color(0xFFE68A8A),
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            error,
            style: const TextStyle(color: Color(0xFFB3B3B3), fontSize: 12),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: onRetry,
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFF5A2A2A)),
              ),
              child: const Text('다시 시도',
                  style: TextStyle(color: Color(0xFFE68A8A))),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEmptyBox(String message) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF131315),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      alignment: Alignment.center,
      child: Text(
        message,
        style: const TextStyle(color: Color(0xFF8A8A8A), fontSize: 13),
      ),
    );
  }
}

// ---------------- constants + helpers ----------------

const Set<String> _kinds = {'body', 'ans', 'sol'};

int _kindOrder(String kind) {
  switch (kind) {
    case 'body':
      return 0;
    case 'sol':
      return 1;
    case 'ans':
      return 2;
    default:
      return 9;
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

String _fmtSize(int bytes) {
  if (bytes <= 0) return '-';
  const units = ['B', 'KB', 'MB', 'GB'];
  double value = bytes.toDouble();
  int unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}

// ---------------- small widgets ----------------

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    late final String label;
    late final Color bg;
    late final Color fg;
    switch (status) {
      case 'legacy':
        label = 'Dropbox';
        bg = const Color(0xFF2D2419);
        fg = const Color(0xFFEAB968);
        break;
      case 'dual':
        label = 'Dual';
        bg = const Color(0xFF1B2B1B);
        fg = const Color(0xFF7CC67C);
        break;
      case 'migrated':
        label = 'Supabase';
        bg = const Color(0xFF1B2430);
        fg = const Color(0xFF7AA9E6);
        break;
      default:
        label = '없음';
        bg = const Color(0xFF222222);
        fg = const Color(0xFF808080);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final Color fg = onPressed == null
        ? const Color(0xFF4A4A4A)
        : (danger ? const Color(0xFFE68A8A) : const Color(0xFFE0E0E0));
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 14, color: fg),
      label: Text(
        label,
        style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w600),
      ),
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 30),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

class _NewRowPicker extends StatefulWidget {
  const _NewRowPicker({required this.onSubmit});
  final void Function(String grade, String kind) onSubmit;

  @override
  State<_NewRowPicker> createState() => _NewRowPickerState();
}

class _NewRowPickerState extends State<_NewRowPicker> {
  final TextEditingController _gradeCtrl = TextEditingController();
  String _kind = 'body';

  @override
  void dispose() {
    _gradeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 150,
          child: TextField(
            controller: _gradeCtrl,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: const InputDecoration(
              hintText: '학년 라벨 (예: 고1)',
              hintStyle: TextStyle(color: Color(0xFF6A6A6A), fontSize: 12),
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              filled: true,
              fillColor: Color(0xFF15171C),
              border: OutlineInputBorder(
                borderSide: BorderSide(color: Color(0xFF2A2A2A)),
                borderRadius: BorderRadius.all(Radius.circular(6)),
              ),
              focusedBorder: OutlineInputBorder(
                borderSide: BorderSide(color: Color(0xFF33A373)),
                borderRadius: BorderRadius.all(Radius.circular(6)),
              ),
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: Color(0xFF2A2A2A)),
                borderRadius: BorderRadius.all(Radius.circular(6)),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        DropdownButton<String>(
          value: _kind,
          dropdownColor: const Color(0xFF15171C),
          style: const TextStyle(color: Colors.white, fontSize: 13),
          underline: const SizedBox.shrink(),
          items: const [
            DropdownMenuItem(value: 'body', child: Text('본문')),
            DropdownMenuItem(value: 'sol', child: Text('해설')),
            DropdownMenuItem(value: 'ans', child: Text('정답')),
          ],
          onChanged: (v) {
            if (v == null) return;
            setState(() => _kind = v);
          },
        ),
        const SizedBox(width: 8),
        _ActionButton(
          icon: Icons.upload_file,
          label: '새 행 업로드',
          onPressed: () {
            final g = _gradeCtrl.text.trim();
            if (g.isEmpty) return;
            widget.onSubmit(g, _kind);
          },
        ),
      ],
    );
  }
}

// ---------------- data classes ----------------

class _MigBook {
  const _MigBook({
    required this.id,
    required this.name,
    required this.academyId,
    required this.orderIndex,
    required this.isPublished,
  });
  final String id;
  final String name;
  final String? academyId;
  final int? orderIndex;
  final bool isPublished;
}

class _MigLink {
  const _MigLink({
    required this.id,
    required this.academyId,
    required this.fileId,
    required this.gradeLabel,
    required this.kind,
    required this.url,
    required this.storageDriver,
    required this.storageBucket,
    required this.storageKey,
    required this.migrationStatus,
    required this.fileSizeBytes,
    required this.contentHash,
    required this.uploadedAt,
  });

  final int id;
  final String academyId;
  final String fileId;
  final String gradeLabel;
  final String kind;
  final String url;
  final String storageDriver;
  final String storageBucket;
  final String storageKey;
  final String migrationStatus;
  final int fileSizeBytes;
  final String contentHash;
  final String uploadedAt;
}
