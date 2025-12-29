import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';
import 'package:open_filex/open_filex.dart';
import 'package:uuid/uuid.dart';

import '../../services/data_manager.dart';

// NOTE: RightSideSheet의 private 색상 상수(_rsBg 등)에는 접근할 수 없어서,
// 동일 톤의 색상을 여기에서 다시 정의합니다. (디자인을 유지하기 위한 중복)
const Color _rsBg = Color(0xFF0B1112);
const Color _rsPanelBg = Color(0xFF10171A);
const Color _rsFieldBg = Color(0xFF15171C);
const Color _rsBorder = Color(0xFF223131);
const Color _rsText = Color(0xFFEAF2F2);
const Color _rsTextSub = Color(0xFF9FB3B3);
const Color _rsAccent = Color(0xFF33A373);

/// 파일 바로가기 탭(범주 -> 폴더(1-depth) -> 파일(HWP/PDF) 바로가기)
///
/// - 범주/폴더 CRUD는 상단 동일 버튼(추가/수정/삭제)로 처리
/// - Overlay 컨텍스트( Navigator 없음 )에서도 동작하도록 dialogContext를 사용해 showDialog 호출
/// - 서버 저장은 resource_folders/resource_files를 category='file_shortcut'로 사용
class FileShortcutTab extends StatefulWidget {
  final BuildContext? dialogContext;
  const FileShortcutTab({super.key, this.dialogContext});

  @override
  State<FileShortcutTab> createState() => _FileShortcutTabState();
}

class _FileShortcutTabState extends State<FileShortcutTab> {
  static const String _kCategoryKey = 'file_shortcut';

  final ScrollController _scrollCtrl = ScrollController();
  bool _loading = false;

  List<_FsCategory> _categories = <_FsCategory>[];
  String? _selectedCategoryId;
  String? _selectedFolderId;
  _FsTarget _target = _FsTarget.category;

  // 삭제 동기화를 위해 현재(서버/로컬)에 존재하는 파일 id 집합을 추적
  Set<String> _knownFileIds = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  BuildContext get _dlgCtx => widget.dialogContext ?? context;

  String? get _effectiveCategoryId {
    if (_categories.isEmpty) return null;
    final cur = _selectedCategoryId;
    if (cur != null && cur.trim().isNotEmpty) {
      final idx = _categories.indexWhere((c) => c.id == cur);
      if (idx != -1) return _categories[idx].id;
    }
    return _categories.first.id;
  }

  _FsCategory? get _effectiveCategory {
    final id = _effectiveCategoryId;
    if (id == null) return null;
    final idx = _categories.indexWhere((c) => c.id == id);
    if (idx == -1) return null;
    return _categories[idx];
  }

  _FsFolder? get _selectedFolder {
    final cat = _effectiveCategory;
    final folderId = _selectedFolderId;
    if (cat == null || folderId == null || folderId.trim().isEmpty) return null;
    return cat.folders.firstWhere((f) => f.id == folderId, orElse: () => const _FsFolder.none());
  }

  Future<void> _reload() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final folderRows = await DataManager.instance.loadResourceFoldersForCategory(_kCategoryKey);
      final fileRows = await DataManager.instance.loadResourceFilesForCategory(_kCategoryKey);

      final categories = _parseFolders(folderRows);
      final filesByFolder = _parseFilesByFolder(fileRows);

      // attach files
      final nextCats = categories.map((c) {
        final nextFolders = c.folders.map((f) {
          final files = filesByFolder[f.id] ?? const <_FsFile>[];
          return f.copyWith(files: files);
        }).toList();
        return c.copyWith(folders: nextFolders);
      }).toList();

      final known = <String>{};
      for (final c in nextCats) {
        for (final f in c.folders) {
          for (final x in f.files) {
            known.add(x.id);
          }
        }
      }

      setState(() {
        _categories = nextCats;
        _knownFileIds = known;
        // 선택 정리
        final eff = _effectiveCategoryId;
        if (eff == null) {
          _selectedCategoryId = null;
          _selectedFolderId = null;
          _target = _FsTarget.category;
        } else {
          _selectedCategoryId = eff;
          if (_selectedFolderId != null) {
            final cat = _categories.firstWhere((c) => c.id == eff);
            final ok = cat.folders.any((f) => f.id == _selectedFolderId);
            if (!ok) _selectedFolderId = null;
          }
        }
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<_FsCategory> _parseFolders(List<Map<String, dynamic>> rows) {
    final cats = <_FsCategory>[];
    final foldersByCat = <String, List<_FsFolder>>{};

    for (final r in rows) {
      final id = (r['id'] as String?) ?? '';
      if (id.isEmpty) continue;
      final name = (r['name'] as String?) ?? '';
      final parent = (r['parent_id'] as String?)?.trim();
      final ord = (r['order_index'] as int?) ?? 0;
      if (parent == null || parent.isEmpty) {
        cats.add(_FsCategory(id: id, name: name, order: ord));
      } else {
        final list = foldersByCat.putIfAbsent(parent, () => <_FsFolder>[]);
        list.add(_FsFolder(id: id, name: name, expanded: false, order: ord));
      }
    }

    cats.sort((a, b) {
      final t = a.order.compareTo(b.order);
      if (t != 0) return t;
      return a.name.compareTo(b.name);
    });

    for (final c in cats) {
      final fs = foldersByCat[c.id] ?? <_FsFolder>[];
      fs.sort((a, b) {
        final t = a.order.compareTo(b.order);
        if (t != 0) return t;
        return a.name.compareTo(b.name);
      });
      c.folders = fs;
    }

    return cats;
  }

  Map<String, List<_FsFile>> _parseFilesByFolder(List<Map<String, dynamic>> rows) {
    final out = <String, List<_FsFile>>{};
    for (final r in rows) {
      final id = (r['id'] as String?) ?? '';
      if (id.isEmpty) continue;
      final folderId = (r['parent_id'] as String?)?.trim() ?? '';
      if (folderId.isEmpty) continue;
      final name = (r['name'] as String?) ?? '';
      final url = (r['url'] as String?) ?? '';
      final ord = (r['order_index'] as int?) ?? 0;
      final kind = _FsFileKind.fromPath(url);
      out.putIfAbsent(folderId, () => <_FsFile>[]).add(_FsFile(
        id: id,
        name: name,
        path: url,
        kind: kind,
        order: ord,
      ));
    }
    for (final e in out.entries) {
      e.value.sort((a, b) {
        final t = a.order.compareTo(b.order);
        if (t != 0) return t;
        return a.name.compareTo(b.name);
      });
    }
    return out;
  }

  Future<void> _persistAll() async {
    // 1) 폴더(범주/폴더) 전체 저장
    final folderRows = <Map<String, dynamic>>[];
    for (int ci = 0; ci < _categories.length; ci++) {
      final c = _categories[ci];
      folderRows.add({
        'id': c.id,
        'name': c.name,
        'parent_id': null,
        'order_index': ci,
      });
      for (int fi = 0; fi < c.folders.length; fi++) {
        final f = c.folders[fi];
        folderRows.add({
          'id': f.id,
          'name': f.name,
          'parent_id': c.id,
          'order_index': fi,
        });
      }
    }
    await DataManager.instance.saveResourceFoldersForCategory(_kCategoryKey, folderRows);

    // 2) 파일 upsert + 삭제 동기화
    final newIds = <String>{};
    final futures = <Future<void>>[];
    for (final c in _categories) {
      for (int fi = 0; fi < c.folders.length; fi++) {
        final folder = c.folders[fi];
        for (int xi = 0; xi < folder.files.length; xi++) {
          final x = folder.files[xi];
          newIds.add(x.id);
          final row = <String, dynamic>{
            'id': x.id,
            'parent_id': folder.id,
            'name': x.name,
            'url': x.path,
            'order_index': xi,
          };
          futures.add(DataManager.instance.saveResourceFileWithCategory(row, _kCategoryKey));
        }
      }
    }

    final removed = _knownFileIds.difference(newIds);
    for (final id in removed) {
      futures.add(DataManager.instance.deleteResourceFile(id));
    }
    await Future.wait(futures);

    _knownFileIds = newIds;
  }

  void _selectCategory(String categoryId) {
    if (_selectedCategoryId == categoryId) return;
    setState(() {
      _selectedCategoryId = categoryId;
      _selectedFolderId = null;
      _target = _FsTarget.category;
    });
  }

  void _selectFolder(String folderId) {
    if (_selectedFolderId == folderId && _target == _FsTarget.folder) return;
    setState(() {
      _selectedFolderId = folderId;
      _target = _FsTarget.folder;
    });
  }

  void _toggleFolderExpanded(String folderId) {
    final catId = _effectiveCategoryId;
    if (catId == null) return;
    final ci = _categories.indexWhere((c) => c.id == catId);
    if (ci == -1) return;
    final folders = _categories[ci].folders;
    final idx = folders.indexWhere((f) => f.id == folderId);
    if (idx == -1) return;
    final nextFolders = [...folders];
    nextFolders[idx] = nextFolders[idx].copyWith(expanded: !nextFolders[idx].expanded);
    setState(() {
      _categories[ci] = _categories[ci].copyWith(folders: nextFolders);
    });
  }

  Future<String?> _promptText({
    required String title,
    required String hintText,
    required String okText,
    String initialText = '',
  }) async {
    return await showDialog<String>(
      context: _dlgCtx,
      useRootNavigator: true,
      barrierDismissible: true,
      builder: (_) => _SimpleTextInputDialog(
        title: title,
        hintText: hintText,
        okText: okText,
        initialText: initialText,
      ),
    );
  }

  Future<bool> _confirmDelete({
    required String title,
    required String message,
  }) async {
    final ok = await showDialog<bool>(
      context: _dlgCtx,
      useRootNavigator: true,
      barrierDismissible: true,
      builder: (_) => AlertDialog(
        backgroundColor: _rsBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text(title, style: const TextStyle(color: _rsText, fontWeight: FontWeight.w900)),
        content: Text(message, style: const TextStyle(color: _rsTextSub, fontWeight: FontWeight.w700, height: 1.25)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(_dlgCtx).pop(false),
            child: const Text('취소', style: TextStyle(color: Colors.white70)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(_dlgCtx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFB74C4C)),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _onCreatePressed() async {
    if (_target == _FsTarget.category || _effectiveCategoryId == null) {
      final name = await _promptText(title: '범주 생성', hintText: '범주 이름', okText: '생성');
      final trimmed = name?.trim() ?? '';
      if (trimmed.isEmpty) return;
      final id = const Uuid().v4();
      setState(() {
        _categories = [
          _FsCategory(id: id, name: trimmed, order: 0, folders: <_FsFolder>[]),
          ..._categories.map((c) => c.copyWith(order: c.order + 1)),
        ];
        _selectedCategoryId = id;
        _selectedFolderId = null;
        _target = _FsTarget.category;
      });
      await _persistAll();
      return;
    }

    final catId = _effectiveCategoryId;
    if (catId == null) return;
    final ci = _categories.indexWhere((c) => c.id == catId);
    if (ci == -1) return;
    final name = await _promptText(title: '폴더 생성', hintText: '폴더 이름', okText: '생성');
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty) return;
    final folderId = const Uuid().v4();
    final cat = _categories[ci];
    final nextFolders = [
      _FsFolder(id: folderId, name: trimmed, expanded: true, order: 0),
      ...cat.folders.map((f) => f.copyWith(order: f.order + 1)),
    ];
    setState(() {
      _categories[ci] = cat.copyWith(folders: nextFolders);
      _selectedFolderId = folderId;
      _target = _FsTarget.folder;
    });
    await _persistAll();
  }

  Future<void> _onEditPressed() async {
    if (_target == _FsTarget.category) {
      final catId = _effectiveCategoryId;
      if (catId == null) return;
      final ci = _categories.indexWhere((c) => c.id == catId);
      if (ci == -1) return;
      final cur = _categories[ci];
      final name = await _promptText(title: '범주 수정', hintText: '범주 이름', okText: '저장', initialText: cur.name);
      final trimmed = name?.trim() ?? '';
      if (trimmed.isEmpty || trimmed == cur.name) return;
      setState(() {
        _categories[ci] = cur.copyWith(name: trimmed);
      });
      await _persistAll();
      return;
    }

    final catId = _effectiveCategoryId;
    final folderId = _selectedFolderId;
    if (catId == null || folderId == null || folderId.trim().isEmpty) return;
    final ci = _categories.indexWhere((c) => c.id == catId);
    if (ci == -1) return;
    final cat = _categories[ci];
    final idx = cat.folders.indexWhere((f) => f.id == folderId);
    if (idx == -1) return;
    final cur = cat.folders[idx];
    final name = await _promptText(title: '폴더 수정', hintText: '폴더 이름', okText: '저장', initialText: cur.name);
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == cur.name) return;
    final nextFolders = [...cat.folders];
    nextFolders[idx] = cur.copyWith(name: trimmed);
    setState(() {
      _categories[ci] = cat.copyWith(folders: nextFolders);
    });
    await _persistAll();
  }

  Future<void> _onDeletePressed() async {
    if (_target == _FsTarget.category) {
      final catId = _effectiveCategoryId;
      if (catId == null) return;
      final ci = _categories.indexWhere((c) => c.id == catId);
      if (ci == -1) return;
      final cur = _categories[ci];
      final ok = await _confirmDelete(
        title: '범주 삭제',
        message: '“${cur.name}”을(를) 삭제할까요?\n(하위 폴더/파일 바로가기 포함)',
      );
      if (!ok) return;
      setState(() {
        _categories = [..._categories]..removeAt(ci);
        _selectedFolderId = null;
        _selectedCategoryId = _categories.isEmpty ? null : _categories.first.id;
        _target = _FsTarget.category;
      });
      await _persistAll();
      return;
    }

    final catId = _effectiveCategoryId;
    final folderId = _selectedFolderId;
    if (catId == null || folderId == null || folderId.trim().isEmpty) return;
    final ci = _categories.indexWhere((c) => c.id == catId);
    if (ci == -1) return;
    final cat = _categories[ci];
    final idx = cat.folders.indexWhere((f) => f.id == folderId);
    if (idx == -1) return;
    final cur = cat.folders[idx];
    final ok = await _confirmDelete(
      title: '폴더 삭제',
      message: '“${cur.name}”을(를) 삭제할까요?\n(하위 파일 바로가기 포함)',
    );
    if (!ok) return;
    final nextFolders = [...cat.folders]..removeAt(idx);
    setState(() {
      _categories[ci] = cat.copyWith(folders: nextFolders);
      _selectedFolderId = null;
      _target = _FsTarget.category;
    });
    await _persistAll();
  }

  Future<void> _onAddFilePressed() async {
    final catId = _effectiveCategoryId;
    final folderId = _selectedFolderId;
    if (catId == null || folderId == null || folderId.trim().isEmpty) return;
    final ci = _categories.indexWhere((c) => c.id == catId);
    if (ci == -1) return;
    final cat = _categories[ci];
    final fi = cat.folders.indexWhere((f) => f.id == folderId);
    if (fi == -1) return;

    final typeGroup = XTypeGroup(label: '문서', extensions: const ['pdf', 'hwp']);
    final XFile? xf = await openFile(acceptedTypeGroups: [typeGroup]);
    if (xf == null) return;

    final path = xf.path;
    final name = (xf.name.isNotEmpty) ? xf.name : path.split(RegExp(r'[\\/]')).last;
    final kind = _FsFileKind.fromPath(path);

    final fileId = const Uuid().v4();
    final folder = cat.folders[fi];
    final nextFiles = [...folder.files, _FsFile(id: fileId, name: name, path: path, kind: kind, order: folder.files.length)];
    final nextFolders = [...cat.folders];
    nextFolders[fi] = folder.copyWith(expanded: true, files: nextFiles);
    setState(() {
      _categories[ci] = cat.copyWith(folders: nextFolders);
      _target = _FsTarget.folder;
    });
    await _persistAll();
  }

  Future<void> _openCategoryPicker() async {
    // 범주 선택 UI를 열면 작업 타겟도 "범주"로 둔다.
    if (mounted) {
      setState(() => _target = _FsTarget.category);
    }
    if (_categories.isEmpty) {
      // 범주가 없으면 바로 생성 모드로 유도
      await _onCreatePressed();
      return;
    }

    final picked = await showDialog<String>(
      context: _dlgCtx,
      useRootNavigator: true,
      barrierDismissible: true,
      builder: (_) => _CategoryPickDialog(
        categories: _categories,
        selectedId: _effectiveCategoryId,
      ),
    );
    final id = picked?.trim() ?? '';
    if (id.isEmpty) return;
    _selectCategory(id);
  }

  @override
  Widget build(BuildContext context) {
    final cat = _effectiveCategory;
    final folders = cat?.folders ?? const <_FsFolder>[];

    final hasCategory = cat != null;
    final hasFolder = _selectedFolder != null && _selectedFolder!.id.isNotEmpty;

    final canEdit = (_target == _FsTarget.category && hasCategory) || (_target == _FsTarget.folder && hasFolder);
    final canDelete = canEdit;
    final canAddFile = hasCategory && hasFolder;

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '파일 바로가기',
            style: TextStyle(color: _rsText, fontSize: 16, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 12),
          _ExplorerHeader(
            leading: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '추가(범주/폴더)',
                  onPressed: _loading ? null : () => unawaited(_onCreatePressed()),
                  icon: const Icon(Icons.create_new_folder_outlined, color: Colors.white70, size: 20),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '수정(범주/폴더)',
                  onPressed: (!_loading && canEdit) ? () => unawaited(_onEditPressed()) : null,
                  icon: const Icon(Icons.drive_file_rename_outline, color: Colors.white70, size: 20),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '삭제(범주/폴더)',
                  onPressed: (!_loading && canDelete) ? () => unawaited(_onDeletePressed()) : null,
                  icon: const Icon(Icons.delete_outline, color: Colors.white70, size: 20),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '파일 추가',
                  onPressed: (!_loading && canAddFile) ? () => unawaited(_onAddFilePressed()) : null,
                  icon: const Icon(Icons.note_add_outlined, color: Colors.white70, size: 20),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _CategoryPickerRow(
            label: '범주',
            valueText: hasCategory ? cat!.name : '범주 없음 (추가 버튼으로 생성)',
            selected: _target == _FsTarget.category,
            onTap: _loading ? null : () => unawaited(_openCategoryPicker()),
          ),
          const SizedBox(height: 12),
          InkWell(
            onTap: _loading
                ? null
                : () {
                    // 폴더 헤더를 누르면 "폴더 작업(추가/수정/삭제)" 타겟으로 전환
                    setState(() => _target = _FsTarget.folder);
                  },
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Text(
                    '폴더',
                    style: TextStyle(
                      color: _rsText,
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                      decoration: (_target == _FsTarget.folder) ? TextDecoration.underline : TextDecoration.none,
                      decorationThickness: 2,
                      decorationColor: _rsAccent,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${folders.length}개',
                    style: const TextStyle(color: _rsTextSub, fontSize: 12, fontWeight: FontWeight.w800),
                  ),
                  const Spacer(),
                  if (_loading)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: (!hasCategory)
                ? const _EmptyState(
                    icon: Icons.folder_special_outlined,
                    title: '등록된 범주가 없습니다.',
                    subtitle: '상단 “추가” 버튼으로 먼저 범주를 만들어 주세요.',
                  )
                : (folders.isEmpty
                    ? const _EmptyState(
                        icon: Icons.folder_open,
                        title: '등록된 폴더가 없습니다.',
                        subtitle: '상단 “추가” 버튼으로 폴더를 추가하세요.\n(범주 선택 후 폴더 모드에서 생성)',
                      )
                    : Scrollbar(
                        controller: _scrollCtrl,
                        thumbVisibility: true,
                        child: ListView.separated(
                          controller: _scrollCtrl,
                          itemCount: folders.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final folder = folders[index];
                            final selected = (_selectedFolderId == folder.id) && (_target == _FsTarget.folder);
                            return _FolderNode(
                              folder: folder,
                              selected: selected,
                              onSelect: () => _selectFolder(folder.id),
                              onToggleExpanded: () => _toggleFolderExpanded(folder.id),
                            );
                          },
                        ),
                      )),
          ),
        ],
      ),
    );
  }
}

enum _FsTarget { category, folder }

enum _FsFileKind {
  pdf,
  hwp,
  other;

  static _FsFileKind fromPath(String path) {
    final p = path.trim().toLowerCase();
    if (p.endsWith('.pdf')) return _FsFileKind.pdf;
    if (p.endsWith('.hwp')) return _FsFileKind.hwp;
    return _FsFileKind.other;
  }

  String badgeLabel() {
    switch (this) {
      case _FsFileKind.pdf:
        return 'PDF';
      case _FsFileKind.hwp:
        return 'HWP';
      case _FsFileKind.other:
        return '-';
    }
  }

  IconData icon() {
    switch (this) {
      case _FsFileKind.pdf:
        return Icons.picture_as_pdf_outlined;
      case _FsFileKind.hwp:
        return Icons.description_outlined;
      case _FsFileKind.other:
        return Icons.insert_drive_file_outlined;
    }
  }
}

class _FsFile {
  final String id;
  final String name;
  final String path;
  final _FsFileKind kind;
  final int order;

  const _FsFile({
    required this.id,
    required this.name,
    required this.path,
    required this.kind,
    required this.order,
  });
}

class _FsFolder {
  final String id;
  final String name;
  final bool expanded;
  final int order;
  final List<_FsFile> files;

  const _FsFolder({
    required this.id,
    required this.name,
    required this.expanded,
    required this.order,
    this.files = const <_FsFile>[],
  });

  const _FsFolder.none()
      : id = '',
        name = '',
        expanded = false,
        order = 0,
        files = const <_FsFile>[];

  _FsFolder copyWith({
    String? id,
    String? name,
    bool? expanded,
    int? order,
    List<_FsFile>? files,
  }) {
    return _FsFolder(
      id: id ?? this.id,
      name: name ?? this.name,
      expanded: expanded ?? this.expanded,
      order: order ?? this.order,
      files: files ?? this.files,
    );
  }
}

class _FsCategory {
  final String id;
  String name;
  int order;
  List<_FsFolder> folders;

  _FsCategory({
    required this.id,
    required this.name,
    required this.order,
    List<_FsFolder>? folders,
  }) : folders = folders ?? <_FsFolder>[];

  _FsCategory copyWith({
    String? id,
    String? name,
    int? order,
    List<_FsFolder>? folders,
  }) {
    return _FsCategory(
      id: id ?? this.id,
      name: name ?? this.name,
      order: order ?? this.order,
      folders: folders ?? this.folders,
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

class _CategoryPickerRow extends StatelessWidget {
  final String label;
  final String valueText;
  final bool selected;
  final VoidCallback? onTap;

  const _CategoryPickerRow({
    required this.label,
    required this.valueText,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final border = selected ? _rsAccent : _rsBorder;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          // 범주 행을 누르면 "범주 선택" 뿐 아니라, 작업 타겟도 범주로 둔다.
          onTap?.call();
        },
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: _rsPanelBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: border),
          ),
          child: Row(
            children: [
              Text(label, style: const TextStyle(color: _rsTextSub, fontSize: 12, fontWeight: FontWeight.w900)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  valueText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _rsText, fontSize: 13, fontWeight: FontWeight.w900),
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.expand_more, color: Colors.white54, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _FolderNode extends StatelessWidget {
  final _FsFolder folder;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onToggleExpanded;

  const _FolderNode({
    required this.folder,
    required this.selected,
    required this.onSelect,
    required this.onToggleExpanded,
  });

  @override
  Widget build(BuildContext context) {
    final border = selected ? _rsAccent : _rsBorder.withOpacity(0.9);
    return Container(
      decoration: BoxDecoration(
        color: _rsPanelBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onSelect,
              borderRadius: BorderRadius.circular(14),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: folder.expanded ? '접기' : '펼치기',
                      onPressed: onToggleExpanded,
                      icon: Icon(
                        folder.expanded ? Icons.expand_more : Icons.chevron_right,
                        color: _rsTextSub,
                        size: 20,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    ),
                    const SizedBox(width: 2),
                    const Icon(Icons.folder_outlined, color: Colors.white70, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        folder.name,
                        style: const TextStyle(color: _rsText, fontSize: 14, fontWeight: FontWeight.w900),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${folder.files.length}',
                      style: const TextStyle(color: _rsTextSub, fontSize: 12, fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (folder.expanded) ...[
            const Divider(height: 1, color: Color(0x22FFFFFF)),
            Padding(
              padding: const EdgeInsets.fromLTRB(34, 10, 10, 10),
              child: folder.files.isEmpty
                  ? const Text(
                      '파일 없음 (상단 “파일 추가”로 HWP/PDF 바로가기를 추가할 수 있어요)',
                      style: TextStyle(color: _rsTextSub, fontSize: 12, fontWeight: FontWeight.w700, height: 1.25),
                    )
                  : Column(
                      children: [
                        for (int i = 0; i < folder.files.length; i++) ...[
                          _FileCard(file: folder.files[i]),
                          if (i != folder.files.length - 1) const SizedBox(height: 8),
                        ],
                      ],
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FileCard extends StatelessWidget {
  final _FsFile file;
  const _FileCard({required this.file});

  @override
  Widget build(BuildContext context) {
    final label = file.kind.badgeLabel();
    final icon = file.kind.icon();

    Widget buildBadge() {
      return SizedBox(
        width: 54,
        height: 30,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _rsPanelBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.transparent),
          ),
          child: Center(
            child: Text(
              label,
              style: const TextStyle(color: _rsTextSub, fontSize: 13, fontWeight: FontWeight.w900),
              maxLines: 1,
              overflow: TextOverflow.clip,
              softWrap: false,
            ),
          ),
        ),
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        final p = file.path.trim();
        if (p.isEmpty) return;
        unawaited(OpenFilex.open(p));
      },
      child: Container(
        width: double.infinity,
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
                Icon(icon, color: Colors.white54, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    file.name,
                    style: const TextStyle(color: _rsText, fontSize: 16, fontWeight: FontWeight.w900),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 12),
                buildBadge(),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              file.path,
              style: const TextStyle(color: _rsTextSub, fontSize: 12, fontWeight: FontWeight.w600, height: 1.25),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _rsPanelBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _rsBorder),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: Colors.white24, size: 24),
          const SizedBox(height: 10),
          Text(
            title,
            style: const TextStyle(color: _rsTextSub, fontSize: 12, fontWeight: FontWeight.w800),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: const TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.w600, height: 1.3),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _CategoryPickDialog extends StatelessWidget {
  final List<_FsCategory> categories;
  final String? selectedId;

  const _CategoryPickDialog({
    required this.categories,
    required this.selectedId,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _rsBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: const Text('범주 선택', style: TextStyle(color: _rsText, fontWeight: FontWeight.w900)),
      content: SizedBox(
        width: 420,
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: categories.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final c = categories[index];
            final selected = (selectedId == c.id);
            return Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => Navigator.of(context).pop(c.id),
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: _rsPanelBg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: selected ? _rsAccent : _rsBorder),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.folder_special_outlined, color: Colors.white70, size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          c.name,
                          style: const TextStyle(color: _rsText, fontSize: 14, fontWeight: FontWeight.w900),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (selected) const Icon(Icons.check, color: _rsAccent, size: 18),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('닫기', style: TextStyle(color: Colors.white70)),
        ),
      ],
    );
  }
}

class _SimpleTextInputDialog extends StatefulWidget {
  final String title;
  final String hintText;
  final String okText;
  final String cancelText;
  final String initialText;

  const _SimpleTextInputDialog({
    required this.title,
    required this.hintText,
    required this.okText,
    this.cancelText = '취소',
    this.initialText = '',
  });

  @override
  State<_SimpleTextInputDialog> createState() => _SimpleTextInputDialogState();
}

class _SimpleTextInputDialogState extends State<_SimpleTextInputDialog> {
  late final TextEditingController _ctrl = ImeAwareTextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canOk = _ctrl.text.trim().isNotEmpty;
    return AlertDialog(
      backgroundColor: _rsBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: Text(widget.title, style: const TextStyle(color: _rsText, fontWeight: FontWeight.w900)),
      content: SizedBox(
        width: 360,
        child: TextField(
          controller: _ctrl,
          autofocus: true,
          style: const TextStyle(color: _rsText, fontWeight: FontWeight.w700),
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: widget.hintText,
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
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.cancelText, style: const TextStyle(color: Colors.white70)),
        ),
        FilledButton(
          onPressed: canOk ? () => Navigator.of(context).pop(_ctrl.text.trim()) : null,
          style: FilledButton.styleFrom(backgroundColor: _rsAccent),
          child: Text(widget.okText),
        ),
      ],
    );
  }
}


