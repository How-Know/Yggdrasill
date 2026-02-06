import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'package:uuid/uuid.dart';

import '../../services/academy_db.dart';
import '../../services/data_manager.dart';
import '../../services/tag_preset_service.dart';

// NOTE: RightSideSheet의 private 색상 상수(_rsBg 등)에는 접근할 수 없어서,
// 동일 톤의 색상을 여기에서 다시 정의합니다. (디자인을 유지하기 위한 중복)
const Color _rsBg = Color(0xFF0B1112);
const Color _rsPanelBg = Color(0xFF10171A);
const Color _rsFieldBg = Color(0xFF15171C);
const Color _rsBorder = Color(0xFF223131);
const Color _rsText = Color(0xFFEAF2F2);
const Color _rsTextSub = Color(0xFF9FB3B3);
const Color _rsAccent = Color(0xFF33A373);
const Color _rsHancomBlue = Color(0xFF2A63FF); // 한글(Hancom) 로고 톤(스크린샷 기준으로 근사)

Widget _rsReorderProxyDecorator(Widget child, int index, Animation<double> animation) {
  // 기본 drag proxy는 Material 배경/여백 때문에 다크 UI에서 "흰 테두리/여백"처럼 보일 수 있다.
  // 또한 아이템 사이 간격(Padding)이 proxy에도 포함되면 피드백 위젯이 불필요하게 커 보인다.
  // -> proxy에서는 padding/drag-listener wrapper를 한 겹 벗기고, 투명 Material로만 감싼다.
  Widget inner = child;
  if (inner is ReorderableDragStartListener) {
    inner = inner.child;
  }
  if (inner is Padding) {
    inner = inner.child ?? const SizedBox.shrink();
  }

  return AnimatedBuilder(
    animation: animation,
    builder: (context, _) {
      final t = Curves.easeOutCubic.transform(animation.value);
      final elevation = 8.0 * t;
      final scale = 1.0 + (0.02 * t);
      return Transform.scale(
        scale: scale,
        child: Material(
          color: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          shadowColor: const Color(0x88000000),
          elevation: elevation,
          child: inner,
        ),
      );
    },
  );
}

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

  // 로컬(서버 저장 없음)에서 마지막 선택 범주를 기억
  static const String _spLastSelectedCategoryId = 'file_shortcut_last_selected_category_id';

  // ✅ 탭 재진입(위젯 재생성) 시 "범주 표시가 잠깐 비어있음/불러오는중..." 플리커를 줄이기 위해
  // 마지막으로 렌더링한 상태를 메모리에 보관한다. (앱 실행 중에만 유지)
  static List<_FsCategory>? _memCategories;
  static String? _memSelectedCategoryId;
  static String? _memSelectedFolderId;
  static _FsTarget? _memTarget;
  static Set<String>? _memKnownFileIds;

  final ScrollController _scrollCtrl = ScrollController();
  bool _loading = false;
  bool _booting = true;
  int _mutationRev = 0;

  List<_FsCategory> _categories = <_FsCategory>[];
  String? _selectedCategoryId;
  String? _selectedFolderId;
  _FsTarget _target = _FsTarget.category;

  // 삭제 동기화를 위해 현재(서버/로컬)에 존재하는 파일 id 집합을 추적
  Set<String> _knownFileIds = <String>{};

  static _FsFile _cloneFile(_FsFile x) => _FsFile(
        id: x.id,
        name: x.name,
        path: x.path,
        kind: x.kind,
        order: x.order,
      );

  static _FsFolder _cloneFolder(_FsFolder f) => _FsFolder(
        id: f.id,
        name: f.name,
        expanded: f.expanded,
        order: f.order,
        files: <_FsFile>[for (final x in f.files) _cloneFile(x)],
      );

  static _FsCategory _cloneCategory(_FsCategory c) => _FsCategory(
        id: c.id,
        name: c.name,
        order: c.order,
        folders: <_FsFolder>[for (final f in c.folders) _cloneFolder(f)],
      );

  void _saveMemCache() {
    _memCategories = <_FsCategory>[for (final c in _categories) _cloneCategory(c)];
    _memSelectedCategoryId = _selectedCategoryId;
    _memSelectedFolderId = _selectedFolderId;
    _memTarget = _target;
    _memKnownFileIds = <String>{..._knownFileIds};
  }

  void _restoreMemCache() {
    final cached = _memCategories;
    if (cached == null || cached.isEmpty) return;
    _categories = <_FsCategory>[for (final c in cached) _cloneCategory(c)];
    _selectedCategoryId = _memSelectedCategoryId;
    _selectedFolderId = _memSelectedFolderId;
    _target = _memTarget ?? _FsTarget.category;
    _knownFileIds = _memKnownFileIds != null
        ? <String>{..._memKnownFileIds!}
        : <String>{
            for (final c in _categories)
              for (final f in c.folders)
                for (final x in f.files) x.id,
          };
    // 캐시가 있으면 일단 즉시 표시하고, 최신화는 백그라운드로 진행
    _booting = false;
  }

  @override
  void initState() {
    super.initState();
    _restoreMemCache();
    unawaited(_init());
  }

  // dispose는 아래에서 메모리 캐시와 함께 처리한다.

  Future<void> _init() async {
    // ✅ 서버 저장 없이 "마지막 선택 범주"를 로컬(SharedPreferences)에서 복원
    await _restoreLastSelectedCategoryFromPrefs();
    if (!mounted) return;
    // ✅ 파일 바로가기 탭은 서버 읽기(preferSupabaseRead)가 켜져 있으면
    // 진입 시 네트워크 대기 때문에 로딩이 길어질 수 있다.
    // -> 로컬(SQLite) 캐시를 먼저 빠르게 표시하고, 서버 동기화는 백그라운드로 수행한다.
    unawaited(_bootstrapReload());
  }

  Future<void> _restoreLastSelectedCategoryFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = (prefs.getString(_spLastSelectedCategoryId) ?? '').trim();
      if (id.isEmpty) return;
      // 이미 선택이 있으면(메모리 캐시 등) 덮어쓰지 않음
      if ((_selectedCategoryId ?? '').trim().isNotEmpty) return;
      if (!mounted) return;
      setState(() {
        _selectedCategoryId = id;
        // 범주 변경 시 폴더 선택은 무효가 될 수 있으니 초기화
        _selectedFolderId = null;
        _target = _FsTarget.category;
      });
    } catch (_) {}
  }

  Future<void> _saveLastSelectedCategoryToPrefs(String categoryId) async {
    final id = categoryId.trim();
    if (id.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_spLastSelectedCategoryId, id);
    } catch (_) {}
  }

  @override
  void dispose() {
    _saveMemCache();
    _scrollCtrl.dispose();
    super.dispose();
  }

  BuildContext get _dlgCtx => widget.dialogContext ?? context;

  String _psSingleQuoted(String s) => "'${s.replaceAll("'", "''")}'";

  Future<void> _openPrintDialogForPath(String path) async {
    final p = path.trim();
    if (p.isEmpty) return;
    try {
      if (Platform.isWindows) {
        final q = _psSingleQuoted(p);
        // NOTE: Windows Shell Verb "Print" 동작은 연결된 기본 프로그램에 위임된다.
        // 일부 앱은 인쇄 다이얼로그를 띄우고, 일부는 바로 출력할 수 있다.
        await Process.start(
          'powershell',
          ['-NoProfile', '-Command', 'Start-Process -FilePath $q -Verb Print'],
          runInShell: true,
        );
        return;
      }
    } catch (_) {
      // fallthrough
    }
    // Fallback: 파일을 열어 사용자가 앱에서 인쇄할 수 있게 한다.
    await OpenFilex.open(p);
  }

  Future<void> _renameFile({
    required String folderId,
    required String fileId,
  }) async {
    final catId = _effectiveCategoryId;
    if (catId == null) return;
    final ci = _categories.indexWhere((c) => c.id == catId);
    if (ci == -1) return;
    final cat = _categories[ci];
    final fi = cat.folders.indexWhere((f) => f.id == folderId);
    if (fi == -1) return;
    final folder = cat.folders[fi];
    final xi = folder.files.indexWhere((x) => x.id == fileId);
    if (xi == -1) return;
    final cur = folder.files[xi];

    final name = await _promptText(
      title: '파일 수정',
      hintText: '파일 이름',
      okText: '저장',
      initialText: cur.name,
    );
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == cur.name) return;

    final nextFiles = [...folder.files];
    nextFiles[xi] = _FsFile(
      id: cur.id,
      name: trimmed,
      path: cur.path,
      kind: cur.kind,
      order: cur.order,
    );

    final nextFolders = [...cat.folders];
    nextFolders[fi] = folder.copyWith(files: nextFiles);
    setState(() {
      _categories[ci] = cat.copyWith(folders: nextFolders);
      _target = _FsTarget.folder;
    });
    await _persistAll();
  }

  Future<void> _deleteFile({
    required String folderId,
    required String fileId,
  }) async {
    final catId = _effectiveCategoryId;
    if (catId == null) return;
    final ci = _categories.indexWhere((c) => c.id == catId);
    if (ci == -1) return;
    final cat = _categories[ci];
    final fi = cat.folders.indexWhere((f) => f.id == folderId);
    if (fi == -1) return;
    final folder = cat.folders[fi];
    final xi = folder.files.indexWhere((x) => x.id == fileId);
    if (xi == -1) return;
    final cur = folder.files[xi];

    final ok = await _confirmDelete(
      title: '파일 삭제',
      message: '“${cur.name}”을(를) 삭제할까요?',
    );
    if (!ok) return;

    final kept = [...folder.files]..removeAt(xi);
    final normalized = <_FsFile>[
      for (int i = 0; i < kept.length; i++)
        _FsFile(
          id: kept[i].id,
          name: kept[i].name,
          path: kept[i].path,
          kind: kept[i].kind,
          order: i,
        ),
    ];

    final nextFolders = [...cat.folders];
    nextFolders[fi] = folder.copyWith(files: normalized);
    setState(() {
      _categories[ci] = cat.copyWith(folders: nextFolders);
      _target = _FsTarget.folder;
    });
    await _persistAll();
  }

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

  bool get canEdit {
    final hasCategory = _effectiveCategoryId != null;
    final hasFolder = _selectedFolder != null && _selectedFolder!.id.isNotEmpty;
    return (_target == _FsTarget.category && hasCategory) ||
        (_target == _FsTarget.folder && hasFolder);
  }

  bool get canDelete => canEdit;

  bool get canAddFile {
    final hasCategory = _effectiveCategoryId != null;
    final hasFolder = _selectedFolder != null && _selectedFolder!.id.isNotEmpty;
    return hasCategory && hasFolder;
  }

  Future<void> _bootstrapReload() async {
    final hasLocal = await _reloadFromLocal();
    if (!mounted) return;
    // 서버 우선 모드가 아니면 여기서 종료(로컬이 authoritative)
    // (비어있더라도) "불러오는 중..." 상태는 종료하여 빈 상태 안내를 노출한다.
    if (!TagPresetService.preferSupabaseRead) {
      setState(() => _booting = false);
      return;
    }

    // 로컬 캐시가 비어 있으면: 한 번만 "블로킹 로드"(빈 화면 방지)
    if (!hasLocal) {
      await _reloadFromServer(blocking: true);
      if (mounted) setState(() => _booting = false);
      return;
    }
    // 로컬이 있으면: UI는 즉시 보여주고 서버 동기화는 백그라운드
    setState(() => _booting = false);
    unawaited(_reloadFromServer(blocking: false));
  }

  Future<bool> _reloadFromLocal() async {
    try {
      final res = await Future.wait([
        AcademyDbService.instance.loadResourceFoldersForCategory(_kCategoryKey),
        AcademyDbService.instance.loadResourceFilesForCategory(_kCategoryKey),
      ]);
      if (!mounted) return false;
      final folderRows = (res[0] as List).cast<Map<String, dynamic>>();
      final fileRows = (res[1] as List).cast<Map<String, dynamic>>();
      _applyLoadedRows(folderRows: folderRows, fileRows: fileRows);
      return folderRows.isNotEmpty || fileRows.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> _reloadFromServer({required bool blocking}) async {
    if (_loading) return;
    final startRev = _mutationRev;
    if (blocking) {
      if (mounted) setState(() => _loading = true);
    }
    try {
      final res = await Future.wait([
        DataManager.instance.loadResourceFoldersForCategory(_kCategoryKey),
        DataManager.instance.loadResourceFilesForCategory(_kCategoryKey),
      ]);
      if (!mounted) return;
      // 로딩 중 사용자가 수정/정렬/삭제 등을 수행했으면 서버 결과로 덮어쓰지 않는다.
      if (startRev != _mutationRev) return;

      final folderRows = (res[0] as List).cast<Map<String, dynamic>>();
      final fileRows = (res[1] as List).cast<Map<String, dynamic>>();

      // 다음 진입 속도를 위해 로컬 캐시도 갱신(서버 write 없이 local-only)
      unawaited(AcademyDbService.instance.saveResourceFoldersForCategory(_kCategoryKey, folderRows));
      unawaited(AcademyDbService.instance.saveResourceFilesForCategory(_kCategoryKey, fileRows));

      _applyLoadedRows(folderRows: folderRows, fileRows: fileRows);
      if (mounted) setState(() => _booting = false);
    } catch (_) {
      // 서버 로드 실패 시에도 booting을 끝내서 "범주 없음" 안내를 표시할 수 있게 한다.
      if (mounted) setState(() => _booting = false);
    } finally {
      if (blocking && mounted) setState(() => _loading = false);
    }
  }

  void _applyLoadedRows({
    required List<Map<String, dynamic>> folderRows,
    required List<Map<String, dynamic>> fileRows,
  }) {
    // 확장 상태 유지(2단계 로드/백그라운드 동기화에서 UI가 접히지 않게)
    final expandedByFolderId = <String, bool>{};
    for (final c in _categories) {
      for (final f in c.folders) {
        expandedByFolderId[f.id] = f.expanded;
      }
    }

    final categories = _parseFolders(folderRows);
    final filesByFolder = _parseFilesByFolder(fileRows);

    // attach files + keep expanded
    final nextCats = categories.map((c) {
      final nextFolders = c.folders.map((f) {
        final files = filesByFolder[f.id] ?? const <_FsFile>[];
        final expanded = expandedByFolderId[f.id] ?? f.expanded;
        return f.copyWith(files: files, expanded: expanded);
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
  }

  List<_FsCategory> _parseFolders(List<Map<String, dynamic>> rows) {
    final cats = <_FsCategory>[];
    final foldersByCat = <String, List<_FsFolder>>{};

    for (final r in rows) {
      final id = (r['id'] as String?) ?? '';
      if (id.isEmpty) continue;
      // 일부 구버전/데이터에서 name이 비어있는 케이스가 있어 description을 fallback으로 사용
      final rawName = (r['name'] as String?) ?? '';
      final rawDesc = (r['description'] as String?) ?? '';
      final name = rawName.trim().isNotEmpty ? rawName : rawDesc;
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
    final ordersByFolder = <String, List<Map<String, dynamic>>>{};
    for (final c in _categories) {
      for (int fi = 0; fi < c.folders.length; fi++) {
        final folder = c.folders[fi];
        ordersByFolder[folder.id] = <Map<String, dynamic>>[];
        for (int xi = 0; xi < folder.files.length; xi++) {
          final x = folder.files[xi];
          newIds.add(x.id);
          ordersByFolder[folder.id]!.add({
            'file_id': x.id,
            'order_index': xi,
          });
          final row = <String, dynamic>{
            'id': x.id,
            'parent_id': folder.id,
            'name': x.name,
            'url': x.path,
          };
          futures.add(DataManager.instance.saveResourceFileWithCategory(row, _kCategoryKey));
        }
      }
    }
    for (final entry in ordersByFolder.entries) {
      futures.add(DataManager.instance.saveResourceFileOrders(
        scopeType: 'file_shortcut',
        category: _kCategoryKey,
        parentId: entry.key,
        rows: entry.value,
      ));
    }

    final removed = _knownFileIds.difference(newIds);
    for (final id in removed) {
      futures.add(DataManager.instance.deleteResourceFile(id));
    }
    await Future.wait(futures);

    _knownFileIds = newIds;
    _mutationRev++;
  }

  void _selectCategory(String categoryId) {
    if (_selectedCategoryId == categoryId) return;
    setState(() {
      _selectedCategoryId = categoryId;
      _selectedFolderId = null;
      _target = _FsTarget.category;
    });
    unawaited(_saveLastSelectedCategoryToPrefs(categoryId));
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

  Future<void> _onReorderFolders(int oldIndex, int newIndex) async {
    if (_loading) return;
    final catId = _effectiveCategoryId;
    if (catId == null) return;
    final ci = _categories.indexWhere((c) => c.id == catId);
    if (ci == -1) return;
    final cat = _categories[ci];
    final list = [...cat.folders];
    if (list.length < 2) return;

    final oi = oldIndex.clamp(0, list.length - 1);
    final ni = (newIndex > oldIndex) ? (newIndex - 1) : newIndex;
    final safeNi = ni.clamp(0, list.length - 1);
    final moved = list.removeAt(oi);
    list.insert(safeNi, moved);

    final normalized = <_FsFolder>[
      for (int i = 0; i < list.length; i++) list[i].copyWith(order: i),
    ];

    setState(() {
      _categories[ci] = cat.copyWith(folders: normalized);
      _target = _FsTarget.folder;
    });
    await _persistAll();
  }

  Future<void> _onReorderFiles({
    required String folderId,
    required int oldIndex,
    required int newIndex,
  }) async {
    if (_loading) return;
    final catId = _effectiveCategoryId;
    if (catId == null) return;
    final ci = _categories.indexWhere((c) => c.id == catId);
    if (ci == -1) return;
    final cat = _categories[ci];
    final fi = cat.folders.indexWhere((f) => f.id == folderId);
    if (fi == -1) return;
    final folder = cat.folders[fi];
    final list = [...folder.files];
    if (list.length < 2) return;

    final oi = oldIndex.clamp(0, list.length - 1);
    final ni = (newIndex > oldIndex) ? (newIndex - 1) : newIndex;
    final safeNi = ni.clamp(0, list.length - 1);
    final moved = list.removeAt(oi);
    list.insert(safeNi, moved);

    final normalized = <_FsFile>[
      for (int i = 0; i < list.length; i++)
        _FsFile(
          id: list[i].id,
          name: list[i].name,
          path: list[i].path,
          kind: list[i].kind,
          order: i,
        ),
    ];

    final nextFolders = [...cat.folders];
    nextFolders[fi] = folder.copyWith(files: normalized);
    setState(() {
      _categories[ci] = cat.copyWith(folders: nextFolders);
      _target = _FsTarget.folder;
    });
    await _persistAll();
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
    // UX: "추가"는 항상 다이얼로그를 띄워 범주/폴더 중 선택 가능
    final catId = _effectiveCategoryId;
    final canCreateFolder = catId != null;
    final initialKind = canCreateFolder ? _FsCreateKind.folder : _FsCreateKind.category;

    final result = await showDialog<_FsCreateDialogResult>(
      context: _dlgCtx,
      useRootNavigator: true,
      barrierDismissible: true,
      builder: (_) => _FsCreateDialog(
        canCreateFolder: canCreateFolder,
        categoryName: _effectiveCategory?.name,
        initialKind: initialKind,
      ),
    );
    if (result == null) return;
    final trimmed = result.name.trim();
    if (trimmed.isEmpty) return;

    if (result.kind == _FsCreateKind.category) {
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

    // folder
    if (catId == null) return;
    final ci = _categories.indexWhere((c) => c.id == catId);
    if (ci == -1) return;
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
    final defaultName = (xf.name.isNotEmpty) ? xf.name : path.split(RegExp(r'[\\/]')).last;
    final inputName = await _promptText(
      title: '파일 추가',
      hintText: '표시 이름',
      okText: '추가',
      initialText: defaultName,
    );
    final name = inputName?.trim() ?? '';
    if (name.isEmpty) return;
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

    final bootEmpty = _booting && _categories.isEmpty;
    final hasCategory = cat != null;

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
          _CategoryPickerRow(
            label: '범주',
            valueText: bootEmpty
                ? '불러오는 중...'
                : (hasCategory
                    ? (cat!.name.trim().isNotEmpty ? cat!.name : '불러오는 중...')
                    : '범주 없음 (추가 버튼으로 생성)'),
            selected: _target == _FsTarget.category,
            onTap: (_loading || bootEmpty) ? null : () => unawaited(_openCategoryPicker()),
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
            child: bootEmpty
                ? const _EmptyState(
                    icon: Icons.hourglass_top_rounded,
                    title: '불러오는 중...',
                    subtitle: '저장된 파일 바로가기를 불러오고 있어요.',
                  )
                : (!hasCategory)
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
                        child: ReorderableListView.builder(
                          scrollController: _scrollCtrl,
                          buildDefaultDragHandles: false,
                          proxyDecorator: _rsReorderProxyDecorator,
                          itemCount: folders.length,
                          onReorder: (oldIndex, newIndex) => unawaited(_onReorderFolders(oldIndex, newIndex)),
                          itemBuilder: (context, index) {
                            final folder = folders[index];
                            final selected = (_selectedFolderId == folder.id) && (_target == _FsTarget.folder);
                            return Padding(
                              key: ValueKey(folder.id),
                              padding: EdgeInsets.only(bottom: (index == folders.length - 1) ? 0 : 8),
                              child: _FolderNode(
                                folder: folder,
                                reorderIndex: index,
                                dialogContext: _dlgCtx,
                                selected: selected,
                                onSelect: () => _selectFolder(folder.id),
                                onToggleExpanded: () => _toggleFolderExpanded(folder.id),
                                onPrint: _openPrintDialogForPath,
                                onRenameFile: (fileId) => unawaited(_renameFile(folderId: folder.id, fileId: fileId)),
                                onDeleteFile: (fileId) => unawaited(_deleteFile(folderId: folder.id, fileId: fileId)),
                                onReorderFiles: (oldIndex, newIndex) => unawaited(
                                  _onReorderFiles(folderId: folder.id, oldIndex: oldIndex, newIndex: newIndex),
                                ),
                              ),
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

enum _FsPaperSize {
  followFile, // 기본(파일 설정)
  a4,
  b4,
  k8,
}

extension _FsPaperSizeX on _FsPaperSize {
  String label() {
    switch (this) {
      case _FsPaperSize.followFile:
        return '기본';
      case _FsPaperSize.a4:
        return 'A4';
      case _FsPaperSize.b4:
        return 'B4';
      case _FsPaperSize.k8:
        return '8K';
    }
  }

  // 포인트(1/72 inch) 기준. (A4는 프로젝트 내 다른 코드에서도 595x842 사용)
  Size portraitSizePt() {
    switch (this) {
      case _FsPaperSize.followFile:
        return const Size(0, 0);
      case _FsPaperSize.a4:
        return const Size(595, 842);
      case _FsPaperSize.b4:
        // 한국/일본에서 통용되는 B4(257x364mm)에 가까운 값(포인트)
        return const Size(729, 1032);
      case _FsPaperSize.k8:
        // 8절(8K) 용지에 가까운 값(273x394mm 근사, 포인트)
        return const Size(774, 1118);
    }
  }

  Size orientedFor(Size srcPageSize) {
    if (this == _FsPaperSize.followFile) return srcPageSize;
    final base = portraitSizePt();
    if (base.width <= 0 || base.height <= 0) return srcPageSize;
    final landscape = srcPageSize.width > srcPageSize.height;
    return landscape ? Size(base.height, base.width) : base;
  }
}

enum _FsFileKind {
  pdf,
  hwp,
  other;

  static _FsFileKind fromPath(String path) {
    final p = path.trim().toLowerCase();
    if (p.endsWith('.pdf')) return _FsFileKind.pdf;
    if (p.endsWith('.hwp') || p.endsWith('.hwpx')) return _FsFileKind.hwp;
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
  final int reorderIndex;
  final BuildContext dialogContext;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onToggleExpanded;
  final Future<void> Function(String path) onPrint;
  final void Function(String fileId) onRenameFile;
  final void Function(String fileId) onDeleteFile;
  final void Function(int oldIndex, int newIndex) onReorderFiles;

  const _FolderNode({
    required this.folder,
    required this.reorderIndex,
    required this.dialogContext,
    required this.selected,
    required this.onSelect,
    required this.onToggleExpanded,
    required this.onPrint,
    required this.onRenameFile,
    required this.onDeleteFile,
    required this.onReorderFiles,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _rsPanelBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _rsBorder.withOpacity(0.9)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: Colors.transparent,
            child: ReorderableDelayedDragStartListener(
              index: reorderIndex,
              child: InkWell(
                onTap: () {
                  // 요청: 폴더 카드를 클릭하면 선택 + 펼치기/접기까지
                  onSelect();
                  onToggleExpanded();
                },
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  decoration: BoxDecoration(
                    // 선택 하이라이트는 "폴더 전체"가 아니라 헤더 영역에만 아주 약하게 적용
                    color: selected ? _rsAccent.withOpacity(0.08) : Colors.transparent,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
                  child: Row(
                    children: [
                      Icon(
                        folder.expanded ? Icons.expand_more : Icons.chevron_right,
                        color: _rsTextSub,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      const Icon(Icons.folder_outlined, color: Colors.white70, size: 18),
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
          ),
          if (folder.expanded) ...[
            const Divider(height: 1, color: Color(0x22FFFFFF)),
            Padding(
              // 트리 들여쓰기 과도함을 줄여 카드 폭을 더 채우도록 조정
              padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
              child: folder.files.isEmpty
                  ? const Text(
                      '파일 없음 (상단 “파일 추가”로 HWP/PDF 바로가기를 추가할 수 있어요)',
                      style: TextStyle(color: _rsTextSub, fontSize: 12, fontWeight: FontWeight.w700, height: 1.25),
                    )
                  : ReorderableListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      buildDefaultDragHandles: false,
                      proxyDecorator: _rsReorderProxyDecorator,
                      itemCount: folder.files.length,
                      onReorder: onReorderFiles,
                      itemBuilder: (context, index) {
                        final f = folder.files[index];
                        return ReorderableDelayedDragStartListener(
                          key: ValueKey(f.id),
                          index: index,
                          child: Padding(
                            padding: EdgeInsets.only(bottom: (index == folder.files.length - 1) ? 0 : 8),
                            child: SizedBox(
                              width: double.infinity,
                              child: _FileCard(
                                file: f,
                                dialogContext: dialogContext,
                                onPrint: onPrint,
                                onRename: () => onRenameFile(f.id),
                                onDelete: () => onDeleteFile(f.id),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FileCard extends StatefulWidget {
  final _FsFile file;
  final BuildContext dialogContext;
  final Future<void> Function(String path) onPrint;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  const _FileCard({
    required this.file,
    required this.dialogContext,
    required this.onPrint,
    required this.onRename,
    required this.onDelete,
  });

  @override
  State<_FileCard> createState() => _FileCardState();
}

class _FileCardState extends State<_FileCard> {
  // 셀 선택 학생리스트 액션(수정/삭제)과 동일한 폭/패딩을 사용
  static const double _actionWidth = 140;
  static const String _printTempPrefix = 'fs_print_';
  double _dx = 0.0; // negative = reveal actions
  bool _dragging = false;
  bool _printing = false;
  _FsPaperSize _paperSize = _FsPaperSize.followFile;
  final TextEditingController _pageRangeCtrl = ImeAwareTextEditingController();
  final GlobalKey _paperAnchorKey = GlobalKey();
  OverlayEntry? _paperMenuEntry;
  Completer<_FsPaperSize?>? _paperMenuCompleter;

  void _dismissPaperMenu([_FsPaperSize? picked]) {
    final entry = _paperMenuEntry;
    final c = _paperMenuCompleter;
    _paperMenuEntry = null;
    _paperMenuCompleter = null;
    try {
      entry?.remove();
    } catch (_) {}
    if (c != null && !c.isCompleted) {
      c.complete(picked);
    }
  }

  @override
  void dispose() {
    _dismissPaperMenu();
    _pageRangeCtrl.dispose();
    super.dispose();
  }

  String _psSingleQuoted(String s) => "'${s.replaceAll("'", "''")}'";

  String _paperToPsName(_FsPaperSize p) {
    switch (p) {
      case _FsPaperSize.followFile:
        return '';
      case _FsPaperSize.a4:
        return 'A4';
      case _FsPaperSize.b4:
        return 'B4';
      case _FsPaperSize.k8:
        return '8K';
    }
  }

  Future<void> _cleanupOldPrintTemps({Duration maxAge = const Duration(days: 1)}) async {
    try {
      final dir = await getTemporaryDirectory();
      final now = DateTime.now();
      final entries = dir.listSync();
      for (final e in entries) {
        if (e is! File) continue;
        final name = p.basename(e.path);
        if (!name.startsWith(_printTempPrefix) || !name.toLowerCase().endsWith('.pdf')) continue;
        final stat = e.statSync();
        if (now.difference(stat.modified) > maxAge) {
          try { e.deleteSync(); } catch (_) {}
        }
      }
    } catch (_) {}
  }

  void _scheduleTempDelete(String path) {
    Future<void>.delayed(const Duration(minutes: 10), () async {
      try {
        final f = File(path);
        if (await f.exists()) {
          await f.delete();
        }
      } catch (_) {}
    });
  }

  List<int> _parsePageRange(String input, int pageCount) {
    final cleaned = input.trim();
    if (cleaned.isEmpty) {
      return List<int>.generate(pageCount, (i) => i);
    }
    final normalized = cleaned
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll('~', '-')
        .replaceAll('–', '-')
        .replaceAll('—', '-');
    final tokens = normalized.split(',');
    final seen = <int>{};
    final out = <int>[];
    for (final raw in tokens) {
      if (raw.isEmpty) continue;
      if (raw.contains('-')) {
        final parts = raw.split('-');
        if (parts.length != 2) continue;
        final start = int.tryParse(parts[0]);
        final end = int.tryParse(parts[1]);
        if (start == null || end == null) continue;
        var a = start;
        var b = end;
        if (a > b) {
          final tmp = a;
          a = b;
          b = tmp;
        }
        a = a.clamp(1, pageCount);
        b = b.clamp(1, pageCount);
        for (int i = a; i <= b; i++) {
          final idx = i - 1;
          if (seen.add(idx)) out.add(idx);
        }
      } else {
        final v = int.tryParse(raw);
        if (v == null) continue;
        if (v < 1 || v > pageCount) continue;
        final idx = v - 1;
        if (seen.add(idx)) out.add(idx);
      }
    }
    return out;
  }

  Future<void> _printHwpShellVerbBestEffort({
    required String path,
    required _FsPaperSize paper,
  }) async {
    final p = path.trim();
    if (p.isEmpty) return;
    if (!Platform.isWindows) {
      await widget.onPrint(p);
      return;
    }

    // NOTE:
    // - HWP는 가장 안정적으로 동작하던 방식(Windows Shell Verb "Print")만 사용한다.
    // - 창 숨김/용지 자동 적용은 환경에 따라 인쇄가 깨지는 케이스가 있어, 기본 경로에서는 수행하지 않는다.
    //   (필요 시 별도 옵션/토글로 "실험적" 기능으로 분리하는 것을 권장)
    await widget.onPrint(p);
  }

  Future<void> _pickPaperSizeFrom(BuildContext anchorCtx) async {
    if (_printing) return;
    // RightSideSheet는 Overlay 안에 있어 Navigator overlay(루트)에 붙이면 시트 "밑"으로 깔릴 수 있음.
    // 따라서 동일 Overlay에 OverlayEntry로 직접 띄운다.
    if (_paperMenuEntry != null) {
      _dismissPaperMenu();
      return;
    }

    final overlayState = Overlay.of(context);
    if (overlayState == null) return;

    final overlayObj = overlayState.context.findRenderObject();
    if (overlayObj is! RenderBox) return;
    final overlayBox = overlayObj;

    final anchorObj = anchorCtx.findRenderObject();
    if (anchorObj is! RenderBox) return;
    final anchorBox = anchorObj;

    final globalTopLeft = anchorBox.localToGlobal(Offset.zero);
    final topLeft = overlayBox.globalToLocal(globalTopLeft);
    final anchorRect = topLeft & anchorBox.size;

    final completer = Completer<_FsPaperSize?>();
    _paperMenuCompleter = completer;

    const gap = 8.0;
    const itemHeight = 40.0;

    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) {
        final overlaySize = overlayBox.size;
        final menuWidth = math.max(anchorRect.width, 140.0);
        final menuHeight = itemHeight * _FsPaperSize.values.length;

        double x = anchorRect.left;
        x = x.clamp(gap, overlaySize.width - gap - menuWidth).toDouble();

        double y = anchorRect.bottom + gap;
        if (y + menuHeight > overlaySize.height - gap) {
          y = anchorRect.top - gap - menuHeight;
        }
        y = y.clamp(gap, overlaySize.height - gap - menuHeight).toDouble();

        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _dismissPaperMenu,
              ),
            ),
            Positioned(
              left: x,
              top: y,
              width: menuWidth,
              child: Material(
                color: _rsPanelBg,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: _rsBorder),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final v in _FsPaperSize.values)
                      InkWell(
                        onTap: () => _dismissPaperMenu(v),
                        child: SizedBox(
                          height: itemHeight,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    v.label(),
                                    style: TextStyle(
                                      color: v == _paperSize ? _rsText : _rsTextSub,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ),
                                if (v == _paperSize)
                                  const Icon(Icons.check, size: 18, color: _rsAccent),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );

    _paperMenuEntry = entry;
    overlayState.insert(entry);

    final picked = await completer.future;
    if (picked == null) return;
    if (!mounted) return;
    setState(() => _paperSize = picked);
  }

  void _close() {
    if (_dx == 0) return;
    setState(() {
      _dx = 0.0;
      _dragging = false;
    });
  }

  void _open() {
    setState(() {
      _dx = -_actionWidth;
      _dragging = false;
    });
  }

  Future<String?> _buildPdfForPrint({
    required String inputPath,
    required _FsPaperSize paper,
    String? pageRange,
  }) async {
    final inPath = inputPath.trim();
    if (inPath.isEmpty) return null;
    if (!inPath.toLowerCase().endsWith('.pdf')) return null;
    final srcBytes = await File(inPath).readAsBytes();
    final src = sf.PdfDocument(inputBytes: srcBytes);
    final dst = sf.PdfDocument();
    try {
      dst.pageSettings.margins.all = 0;
    } catch (_) {}

    try {
      final pageCount = src.pages.count;
      final indices = _parsePageRange(pageRange ?? '', pageCount);
      if (indices.isEmpty) return null;
      for (final i in indices) {
        if (i < 0 || i >= pageCount) continue;
        final srcPage = src.pages[i];
        final srcSize = srcPage.size;
        final target = paper.orientedFor(srcSize);
        try {
          dst.pageSettings.size = target;
          dst.pageSettings.margins.all = 0;
        } catch (_) {}

        final tmpl = srcPage.createTemplate();
        final newPage = dst.pages.add();

        final tw = target.width;
        final th = target.height;
        final sw = srcSize.width;
        final sh = srcSize.height;
        if (tw <= 0 || th <= 0 || sw <= 0 || sh <= 0) {
          newPage.graphics.drawPdfTemplate(tmpl, const Offset(0, 0));
          continue;
        }

        final scale = math.min(tw / sw, th / sh);
        final w = sw * scale;
        final h = sh * scale;
        final dx = (tw - w) / 2.0;
        final dy = (th - h) / 2.0;

        try {
          newPage.graphics.drawPdfTemplate(tmpl, Offset(dx, dy), Size(w, h));
        } catch (_) {
          newPage.graphics.drawPdfTemplate(tmpl, const Offset(0, 0));
        }
      }

      final outBytes = await dst.save();
      final dir = await getTemporaryDirectory();
      final outPath = p.join(
        dir.path,
        '${_printTempPrefix}${DateTime.now().millisecondsSinceEpoch}_${paper.label()}.pdf',
      );
      await File(outPath).writeAsBytes(outBytes, flush: true);
      return outPath;
    } finally {
      src.dispose();
      dst.dispose();
    }
  }

  Future<void> _printNow() async {
    if (_printing) return;
    final file = widget.file;
    final srcPath = file.path.trim();
    if (srcPath.isEmpty) return;
    setState(() => _printing = true);
    try {
      unawaited(_cleanupOldPrintTemps());
      // HWP는 환경별로 자동화(숨김/키보드) 방식이 쉽게 깨질 수 있어,
      // 가장 안정적인 방식(Windows Shell Verb "Print")으로 위임한다.
      // -> "파일은 안 열리고, 인쇄 진행/대화창만 뜬 뒤 자동 인쇄"가 이 경로에서 동작하는 경우가 많다.
      if (file.kind == _FsFileKind.hwp) {
        await _printHwpShellVerbBestEffort(path: srcPath, paper: _paperSize);
        return;
      }
      String pathToPrint = srcPath;
      String? tempToDelete;
      // 용지 크기 지정은 PDF에서만 적용(새 PDF 생성)
      if (file.kind == _FsFileKind.pdf) {
        final rangeText = _pageRangeCtrl.text.trim();
        if (_paperSize != _FsPaperSize.followFile || rangeText.isNotEmpty) {
          final out = await _buildPdfForPrint(
            inputPath: srcPath,
            paper: _paperSize,
            pageRange: rangeText,
          );
          if (out != null && out.trim().isNotEmpty) {
            pathToPrint = out.trim();
            tempToDelete = pathToPrint;
          } else if (rangeText.isNotEmpty && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('페이지 범위를 확인하세요. (예: 10-15, 20)')),
            );
            return;
          }
        }
      }
      await widget.onPrint(pathToPrint);
      if (tempToDelete != null) {
        _scheduleTempDelete(tempToDelete);
      }
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  Future<void> _pickPaperSize() async {
    if (_printing) return;
    final anchorCtx = _paperAnchorKey.currentContext;
    if (anchorCtx == null) return;
    await _pickPaperSizeFrom(anchorCtx);
  }

  @override
  Widget build(BuildContext context) {
    final file = widget.file;

    Widget buildKindBadge() {
      String? letter;
      Color? color;
      switch (file.kind) {
        case _FsFileKind.hwp:
          letter = 'H';
          color = _rsHancomBlue; // 한글(Hancom)
          break;
        case _FsFileKind.pdf:
          letter = 'P';
          color = const Color(0xFFED1C24); // Adobe 레드 톤
          break;
        case _FsFileKind.other:
          return const SizedBox.shrink();
      }

      return Tooltip(
        message: (file.kind == _FsFileKind.pdf) ? 'PDF' : 'HWP',
        waitDuration: const Duration(milliseconds: 450),
        child: Text(
          letter,
          style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w900),
        ),
      );
    }

    final content = Material(
      color: Colors.transparent,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: _rsFieldBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _rsBorder.withOpacity(0.9)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () {
                if (_dx != 0) {
                  _close();
                  return;
                }
                final p = file.path.trim();
                if (p.isEmpty) return;
                unawaited(OpenFilex.open(p));
              },
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      file.name,
                      style: const TextStyle(color: _rsText, fontSize: 15, fontWeight: FontWeight.w900),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                IconButton(
                  tooltip: (file.kind == _FsFileKind.hwp) ? '바로 인쇄' : '인쇄',
                  onPressed: _printing ? null : () => unawaited(_printNow()),
                  icon: const Icon(Icons.print_outlined, color: Colors.white70, size: 18),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                ),
                const SizedBox(width: 6),
                if (file.kind == _FsFileKind.pdf)
                  InkWell(
                    key: _paperAnchorKey,
                    onTap: (!_printing) ? () => unawaited(_pickPaperSize()) : null,
                    borderRadius: BorderRadius.circular(10),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: _rsPanelBg,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.transparent),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _paperSize.label(),
                              style: const TextStyle(
                                color: _rsTextSub,
                                fontSize: 13,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(width: 2),
                            const Icon(
                              Icons.expand_more,
                              size: 16,
                              color: _rsTextSub,
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                else
                  const SizedBox.shrink(),
                if (file.kind == _FsFileKind.pdf) ...[
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 110,
                    height: 30,
                    child: TextField(
                      controller: _pageRangeCtrl,
                      enabled: !_printing,
                      style: const TextStyle(color: _rsText, fontSize: 12, fontWeight: FontWeight.w700),
                      decoration: InputDecoration(
                        hintText: '페이지 (예: 10-15)',
                        hintStyle: const TextStyle(color: _rsTextSub, fontSize: 11),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: _rsBorder),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: _rsAccent, width: 1.2),
                        ),
                        filled: true,
                        fillColor: _rsPanelBg,
                        isDense: true,
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                buildKindBadge(),
              ],
            ),
          ],
        ),
      ),
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Stack(
        children: [
          Positioned.fill(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                SizedBox(
                  width: _actionWidth,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Material(
                            color: const Color(0xFF223131),
                            borderRadius: BorderRadius.circular(10),
                            child: InkWell(
                              onTap: () {
                                _close();
                                widget.onRename();
                              },
                              borderRadius: BorderRadius.circular(10),
                              splashFactory: NoSplash.splashFactory,
                              highlightColor: Colors.white.withOpacity(0.06),
                              hoverColor: Colors.white.withOpacity(0.03),
                              child: const SizedBox.expand(
                                child: Center(
                                  child: Icon(Icons.edit_outlined, color: Color(0xFFEAF2F2), size: 18),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Material(
                            color: const Color(0xFFB74C4C),
                            borderRadius: BorderRadius.circular(10),
                            child: InkWell(
                              onTap: () {
                                _close();
                                widget.onDelete();
                              },
                              borderRadius: BorderRadius.circular(10),
                              splashFactory: NoSplash.splashFactory,
                              highlightColor: Colors.white.withOpacity(0.08),
                              hoverColor: Colors.white.withOpacity(0.04),
                              child: const SizedBox.expand(
                                child: Center(
                                  child: Icon(Icons.delete_outline_rounded, color: Colors.white, size: 18),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: (_) => setState(() => _dragging = true),
            onHorizontalDragUpdate: (d) {
              setState(() {
                _dx = (_dx + d.delta.dx).clamp(-_actionWidth, 0.0);
              });
            },
            onHorizontalDragEnd: (_) {
              final open = _dx <= -(_actionWidth * 0.55);
              if (open) {
                _open();
              } else {
                _close();
              }
            },
            onHorizontalDragCancel: _close,
            child: AnimatedContainer(
              duration: _dragging ? Duration.zero : const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              transform: Matrix4.translationValues(_dx, 0, 0),
              child: content,
            ),
          ),
        ],
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

enum _FsCreateKind { category, folder }

class _FsCreateDialogResult {
  final _FsCreateKind kind;
  final String name;
  const _FsCreateDialogResult({required this.kind, required this.name});
}

class _FsCreateDialog extends StatefulWidget {
  final bool canCreateFolder;
  final String? categoryName;
  final _FsCreateKind initialKind;

  const _FsCreateDialog({
    required this.canCreateFolder,
    required this.categoryName,
    required this.initialKind,
  });

  @override
  State<_FsCreateDialog> createState() => _FsCreateDialogState();
}

class _FsCreateDialogState extends State<_FsCreateDialog> {
  late _FsCreateKind _kind = widget.initialKind;
  late final TextEditingController _ctrl = ImeAwareTextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  bool get _canOk {
    if (_ctrl.text.trim().isEmpty) return false;
    if (_kind == _FsCreateKind.folder && !widget.canCreateFolder) return false;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final folderEnabled = widget.canCreateFolder;
    final folderHint = folderEnabled ? '폴더 이름' : '폴더를 추가하려면 먼저 범주를 선택/생성하세요';
    final hint = (_kind == _FsCreateKind.category) ? '범주 이름' : folderHint;

    Widget kindButton({
      required String label,
      required _FsCreateKind kind,
      required bool enabled,
    }) {
      final selected = (_kind == kind);
      final borderColor = !enabled
          ? _rsBorder.withOpacity(0.35)
          : (selected ? _rsAccent : _rsBorder);
      final bg = selected ? _rsAccent.withOpacity(0.12) : _rsPanelBg;
      final fg = !enabled
          ? Colors.white24
          : (selected ? _rsText : _rsTextSub);

      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: enabled ? () => setState(() => _kind = kind) : null,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            height: 38,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: borderColor),
            ),
            child: Center(
              child: Text(
                label,
                style: TextStyle(color: fg, fontWeight: FontWeight.w900),
              ),
            ),
          ),
        ),
      );
    }

    return AlertDialog(
      backgroundColor: _rsBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: const Text('추가', style: TextStyle(color: _rsText, fontWeight: FontWeight.w900)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: kindButton(
                    label: '범주',
                    kind: _FsCreateKind.category,
                    enabled: true,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: kindButton(
                    label: '폴더',
                    kind: _FsCreateKind.folder,
                    enabled: folderEnabled,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (_kind == _FsCreateKind.folder && widget.categoryName != null) ...[
              Text(
                '현재 범주: ${widget.categoryName}',
                style: const TextStyle(color: _rsTextSub, fontSize: 12, fontWeight: FontWeight.w700),
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
            ],
            TextField(
              controller: _ctrl,
              autofocus: true,
              enabled: !(_kind == _FsCreateKind.folder && !folderEnabled),
              style: const TextStyle(color: _rsText, fontWeight: FontWeight.w700),
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: hint,
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
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소', style: TextStyle(color: Colors.white70)),
        ),
        FilledButton(
          onPressed: _canOk
              ? () => Navigator.of(context).pop(
                    _FsCreateDialogResult(kind: _kind, name: _ctrl.text.trim()),
                  )
              : null,
          style: FilledButton.styleFrom(backgroundColor: _rsAccent),
          child: const Text('생성'),
        ),
      ],
    );
  }
}

class _PaperSizePickDialog extends StatelessWidget {
  final _FsPaperSize selected;
  const _PaperSizePickDialog({required this.selected});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _rsBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: const Text('용지 크기', style: TextStyle(color: _rsText, fontWeight: FontWeight.w900)),
      content: SizedBox(
        width: 320,
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: _FsPaperSize.values.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final v = _FsPaperSize.values[index];
            final isSel = v == selected;
            return Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => Navigator.of(context).pop<_FsPaperSize>(v),
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: _rsPanelBg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: isSel ? _rsAccent : _rsBorder),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          v.label(),
                          style: TextStyle(
                            color: isSel ? _rsText : _rsTextSub,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      if (isSel) const Icon(Icons.check, color: _rsAccent, size: 18),
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


