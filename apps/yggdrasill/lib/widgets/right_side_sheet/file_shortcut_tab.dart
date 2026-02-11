import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

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

/// 파일 바로가기 탭(폴더(기타) -> 파일(HWP/PDF) 바로가기)
///
/// - 폴더(기타) 선택 후 파일 바로가기를 바로 관리
/// - Overlay 컨텍스트( Navigator 없음 )에서도 동작하도록 dialogContext를 사용해 showDialog 호출
/// - 파일 저장은 resource_files (category='file_shortcut')
/// - 상단 폴더 선택은 자료탭 기타(category='other')의 폴더를 사용
class FileShortcutTab extends StatefulWidget {
  final BuildContext? dialogContext;
  const FileShortcutTab({super.key, this.dialogContext});

  @override
  State<FileShortcutTab> createState() => _FileShortcutTabState();
}

class _FileShortcutTabState extends State<FileShortcutTab> {
  static const String _kCategoryKey = 'file_shortcut';
  static const String _kExternalCategoryKey = 'other';

  // 로컬(서버 저장 없음)에서 마지막 선택 폴더를 기억
  static const String _spLastSelectedCategoryId = 'file_shortcut_last_selected_category_id';

  // ✅ 탭 재진입(위젯 재생성) 시 "폴더 표시가 잠깐 비어있음/불러오는중..." 플리커를 줄이기 위해
  // 마지막으로 렌더링한 상태를 메모리에 보관한다. (앱 실행 중에만 유지)
  static List<_FsCategory>? _memCategories;
  static String? _memSelectedCategoryId;
  static Set<String>? _memExternalCategoryIds;

  final ScrollController _scrollCtrl = ScrollController();
  bool _loading = false;
  bool _booting = true;
  int _mutationRev = 0;

  List<_FsCategory> _categories = <_FsCategory>[];
  Set<String> _externalCategoryIds = <String>{};
  String? _selectedCategoryId;

  static _FsFile _cloneFile(_FsFile x) => _FsFile(
        id: x.id,
        name: x.name,
        links: Map<_FsFileKind, String>.from(x.links),
        order: x.order,
      );

  static _FsCategory _cloneCategory(_FsCategory c) => _FsCategory(
        id: c.id,
        name: c.name,
        order: c.order,
        files: <_FsFile>[for (final x in c.filesOrEmpty) _cloneFile(x)],
      );

  void _saveMemCache() {
    _memCategories = <_FsCategory>[for (final c in _categories) _cloneCategory(c)];
    _memSelectedCategoryId = _selectedCategoryId;
    _memExternalCategoryIds = <String>{..._externalCategoryIds};
  }

  void _restoreMemCache() {
    final cached = _memCategories;
    if (cached == null || cached.isEmpty) return;
    _categories = <_FsCategory>[for (final c in cached) _cloneCategory(c)];
    _selectedCategoryId = _memSelectedCategoryId;
    _externalCategoryIds = _memExternalCategoryIds != null ? <String>{..._memExternalCategoryIds!} : <String>{};
    // 캐시가 있으면 일단 즉시 표시하고, 최신화는 백그라운드로 진행
    _booting = false;
  }

  @override
  void initState() {
    super.initState();
    _restoreMemCache();
    unawaited(_init());
  }

  @override
  void reassemble() {
    super.reassemble();
    _memCategories = null;
    _categories = <_FsCategory>[];
    _externalCategoryIds = <String>{};
    _selectedCategoryId = null;
    _booting = true;
    unawaited(_bootstrapReload());
  }

  // dispose는 아래에서 메모리 캐시와 함께 처리한다.

  Future<void> _init() async {
    // ✅ 서버 저장 없이 "마지막 선택 폴더"를 로컬(SharedPreferences)에서 복원
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

  Future<void> _renameFile({required String fileId}) async {
    final catId = _effectiveCategoryId;
    if (catId == null) return;
    final ci = _categories.indexWhere((c) => c.id == catId);
    if (ci == -1) return;
    final cat = _categories[ci];
    final xi = cat.filesOrEmpty.indexWhere((x) => x.id == fileId);
    if (xi == -1) return;
    final cur = cat.filesOrEmpty[xi];

    final name = await _promptText(
      title: '파일 수정',
      hintText: '파일 이름',
      okText: '저장',
      initialText: cur.name,
    );
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == cur.name) return;

    final nextFiles = [...cat.filesOrEmpty];
    nextFiles[xi] = cur.copyWith(name: trimmed);
    setState(() {
      _categories[ci] = cat.copyWith(files: nextFiles);
    });
    _mutationRev++;
    await DataManager.instance.saveResourceFileWithCategory(
      {
        'id': cur.id,
        'name': trimmed,
        'parent_id': catId,
      },
      _kExternalCategoryKey,
    );
  }

  Future<void> _deleteFile({required String fileId}) async {
    final catId = _effectiveCategoryId;
    if (catId == null) return;
    final ci = _categories.indexWhere((c) => c.id == catId);
    if (ci == -1) return;
    final cat = _categories[ci];
    final xi = cat.filesOrEmpty.indexWhere((x) => x.id == fileId);
    if (xi == -1) return;
    final cur = cat.filesOrEmpty[xi];

    final ok = await _confirmDelete(
      title: '파일 삭제',
      message: '“${cur.name}”을(를) 삭제할까요?',
    );
    if (!ok) return;

    final kept = [...cat.filesOrEmpty]..removeAt(xi);
    final normalized = <_FsFile>[
      for (int i = 0; i < kept.length; i++)
        kept[i].copyWith(order: i),
    ];

    setState(() {
      _categories[ci] = cat.copyWith(files: normalized);
    });
    _mutationRev++;
    await DataManager.instance.deleteResourceFile(cur.id);
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
        AcademyDbService.instance.loadResourceFilesForCategory(_kExternalCategoryKey),
        AcademyDbService.instance.loadResourceFoldersForCategory(_kExternalCategoryKey),
      ]);
      if (!mounted) return false;
      final rawFileRows = (res[0] as List).cast<Map<String, dynamic>>();
      final otherFolderRows = (res[1] as List).cast<Map<String, dynamic>>();
      final fileRows = await _applyShortcutOrdersIfAny(rawFileRows);
      final linksByFileId = await _loadLinksByFileId(fileRows);
      _applyLoadedRows(fileRows: fileRows, otherFolderRows: otherFolderRows, linksByFileId: linksByFileId);
      unawaited(AcademyDbService.instance.saveResourceFoldersForCategory(_kCategoryKey, const <Map<String, dynamic>>[]));
      return rawFileRows.isNotEmpty || otherFolderRows.isNotEmpty;
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
        DataManager.instance.loadResourceFilesForCategory(_kExternalCategoryKey),
        DataManager.instance.loadResourceFoldersForCategory(_kExternalCategoryKey),
        DataManager.instance.loadResourceFoldersForCategory(_kCategoryKey),
        DataManager.instance.loadResourceFilesForCategory(_kCategoryKey),
      ]);
      if (!mounted) return;
      // 로딩 중 사용자가 수정/정렬/삭제 등을 수행했으면 서버 결과로 덮어쓰지 않는다.
      if (startRev != _mutationRev) return;

      final rawFileRows = (res[0] as List).cast<Map<String, dynamic>>();
      final otherFolderRows = (res[1] as List).cast<Map<String, dynamic>>();
      final legacyFolderRows = (res[2] as List).cast<Map<String, dynamic>>();
      final legacyFileRows = (res[3] as List).cast<Map<String, dynamic>>();
      final fileRows = await _applyShortcutOrdersIfAny(rawFileRows);

      // 다음 진입 속도를 위해 로컬 캐시도 갱신(서버 write 없이 local-only)
      unawaited(AcademyDbService.instance.saveResourceFoldersForCategory(_kCategoryKey, const <Map<String, dynamic>>[]));
      unawaited(AcademyDbService.instance.saveResourceFilesForCategory(_kExternalCategoryKey, rawFileRows));
      unawaited(AcademyDbService.instance.saveResourceFoldersForCategory(_kExternalCategoryKey, otherFolderRows));

      final linksByFileId = await _loadLinksByFileId(fileRows);
      _applyLoadedRows(fileRows: fileRows, otherFolderRows: otherFolderRows, linksByFileId: linksByFileId);
      if (legacyFolderRows.isNotEmpty) {
        unawaited(DataManager.instance.saveResourceFoldersForCategory(_kCategoryKey, const <Map<String, dynamic>>[]));
      }
      if (legacyFileRows.isNotEmpty) {
        unawaited(_cleanupLegacyShortcutFiles(legacyFileRows));
      }
      if (mounted) setState(() => _booting = false);
    } catch (_) {
      // 서버 로드 실패 시에도 booting을 끝내서 "폴더 없음" 안내를 표시할 수 있게 한다.
      if (mounted) setState(() => _booting = false);
    } finally {
      if (blocking && mounted) setState(() => _loading = false);
    }
  }

  void _applyLoadedRows({
    required List<Map<String, dynamic>> fileRows,
    required List<Map<String, dynamic>> otherFolderRows,
    required Map<String, Map<String, String>> linksByFileId,
  }) {
    final externalCategories = _parseExternalCategories(otherFolderRows);
    _externalCategoryIds = <String>{for (final c in externalCategories) c.id};
    final filesByFolder = _parseFilesByFolder(fileRows, linksByFileId);

    final nextCats = externalCategories.map((c) {
      final files = filesByFolder[c.id] ?? const <_FsFile>[];
      return c.copyWith(files: files);
    }).toList();

    final nextSelected = (() {
      if (nextCats.isEmpty) return null;
      final cur = _selectedCategoryId;
      if (cur != null && nextCats.any((c) => c.id == cur)) return cur;
      return nextCats.first.id;
    })();

    setState(() {
      _categories = nextCats;
      _selectedCategoryId = nextSelected;
    });
  }

  List<_FsCategory> _parseExternalCategories(List<Map<String, dynamic>> rows) {
    final items = <String, _FsExternalFolderRow>{};
    for (final r in rows) {
      final id = (r['id'] as String?) ?? '';
      if (id.isEmpty) continue;
      // 일부 구버전/데이터에서 name이 비어있는 케이스가 있어 description을 fallback으로 사용
      final rawName = (r['name'] as String?) ?? '';
      final rawDesc = (r['description'] as String?) ?? '';
      final name = rawName.trim().isNotEmpty ? rawName : rawDesc;
      final safeName = name.trim().isNotEmpty ? name : id;
      final parent = (r['parent_id'] as String?)?.trim() ?? '';
      final ord = (r['order_index'] as int?) ?? 0;
      items[id] = _FsExternalFolderRow(id: id, name: safeName, parentId: parent, order: ord);
    }

    String buildPath(String id, Set<String> visited) {
      final node = items[id];
      if (node == null) return '';
      if (visited.contains(id)) return node.name;
      visited.add(id);
      if (node.parentId.isEmpty || !items.containsKey(node.parentId)) {
        return node.name;
      }
      final parentName = buildPath(node.parentId, visited);
      if (parentName.isEmpty) return node.name;
      return '$parentName / ${node.name}';
    }

    final out = <_FsCategory>[];
    for (final node in items.values) {
      final label = buildPath(node.id, <String>{});
      out.add(_FsCategory(id: node.id, name: label, order: node.order));
    }
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  Future<List<Map<String, dynamic>>> _applyShortcutOrdersIfAny(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return rows;
    try {
      final orders = await AcademyDbService.instance.loadResourceFileOrders(
        scopeType: 'file_shortcut',
        category: _kCategoryKey,
      );
      if (orders.isEmpty) return rows;
      final orderByKey = <String, int>{};
      for (final o in orders) {
        final fileId = (o['file_id'] as String?) ?? '';
        if (fileId.isEmpty) continue;
        final parent = (o['parent_id'] as String?)?.trim() ?? '';
        final order = (o['order_index'] as int?) ?? 0;
        orderByKey['$fileId|$parent'] = order;
      }
      if (orderByKey.isEmpty) return rows;
      for (final row in rows) {
        final fileId = (row['id'] as String?) ?? '';
        if (fileId.isEmpty) continue;
        final parent = (row['parent_id'] as String?)?.trim() ?? '';
        final key = '$fileId|$parent';
        if (orderByKey.containsKey(key)) {
          row['order_index'] = orderByKey[key];
        }
      }
    } catch (_) {}
    return rows;
  }

  Future<Map<String, Map<String, String>>> _loadLinksByFileId(List<Map<String, dynamic>> rows) async {
    final ids = <String>{};
    for (final r in rows) {
      final id = (r['id'] as String?) ?? '';
      if (id.isNotEmpty) ids.add(id);
    }
    if (ids.isEmpty) return <String, Map<String, String>>{};
    final out = <String, Map<String, String>>{};
    final futures = <Future<void>>[];
    for (final id in ids) {
      futures.add(() async {
        try {
          out[id] = await DataManager.instance.loadResourceFileLinks(id);
        } catch (_) {
          out[id] = <String, String>{};
        }
      }());
    }
    await Future.wait(futures);
    return out;
  }

  Map<_FsFileKind, String> _normalizeLinks(Map<String, String> raw) {
    final out = <_FsFileKind, String>{};
    for (final e in raw.entries) {
      final key = e.key.trim().toLowerCase();
      final value = e.value.trim();
      if (value.isEmpty) continue;
      if (key == 'pdf') {
        out[_FsFileKind.pdf] = value;
      } else if (key == 'hwp' || key == 'hwpx') {
        out[_FsFileKind.hwp] = value;
      }
    }
    if (out.isEmpty) {
      for (final value in raw.values) {
        final v = value.trim();
        if (v.isEmpty) continue;
        final kind = _FsFileKind.fromPath(v);
        if (kind != _FsFileKind.other && !out.containsKey(kind)) {
          out[kind] = v;
        }
      }
    }
    return out;
  }

  Map<String, List<_FsFile>> _parseFilesByFolder(
    List<Map<String, dynamic>> rows,
    Map<String, Map<String, String>> linksByFileId,
  ) {
    final out = <String, List<_FsFile>>{};
    for (final r in rows) {
      final id = (r['id'] as String?) ?? '';
      if (id.isEmpty) continue;
      final folderId = (r['parent_id'] as String?)?.trim() ?? '';
      if (folderId.isEmpty) continue;
      final rawName = (r['name'] as String?) ?? '';
      final rawDesc = (r['description'] as String?) ?? '';
      final name = rawName.trim().isNotEmpty ? rawName : rawDesc;
      final safeName = name.trim().isNotEmpty ? name : id;
      final url = (r['url'] as String?) ?? '';
      final ord = (r['order_index'] as int?) ?? 0;
      final links = _normalizeLinks(linksByFileId[id] ?? const <String, String>{});
      final fallbackKind = _FsFileKind.fromPath(url);
      final fallbackLinks = links.isEmpty && url.trim().isNotEmpty && fallbackKind != _FsFileKind.other
          ? <_FsFileKind, String>{fallbackKind: url}
          : links;
      if (fallbackLinks.isEmpty) continue;
      out.putIfAbsent(folderId, () => <_FsFile>[]).add(_FsFile(
        id: id,
        name: safeName,
        links: fallbackLinks,
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

  Future<void> _cleanupLegacyShortcutFiles(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return;
    final futures = <Future<void>>[];
    for (final r in rows) {
      final id = (r['id'] as String?) ?? '';
      if (id.isEmpty) continue;
      futures.add(DataManager.instance.deleteResourceFile(id));
    }
    if (futures.isNotEmpty) {
      await Future.wait(futures);
    }
  }

  void _selectCategory(String categoryId) {
    if (_selectedCategoryId == categoryId) return;
    setState(() {
      _selectedCategoryId = categoryId;
    });
    unawaited(_saveLastSelectedCategoryToPrefs(categoryId));
  }

  Future<void> _onReorderFiles({
    required int oldIndex,
    required int newIndex,
  }) async {
    if (_loading) return;
    final catId = _effectiveCategoryId;
    if (catId == null) return;
    final ci = _categories.indexWhere((c) => c.id == catId);
    if (ci == -1) return;
    final cat = _categories[ci];
    final list = [...cat.filesOrEmpty];
    if (list.length < 2) return;

    final oi = oldIndex.clamp(0, list.length - 1);
    final ni = (newIndex > oldIndex) ? (newIndex - 1) : newIndex;
    final safeNi = ni.clamp(0, list.length - 1);
    final moved = list.removeAt(oi);
    list.insert(safeNi, moved);

    final normalized = <_FsFile>[
      for (int i = 0; i < list.length; i++)
        list[i].copyWith(order: i),
    ];

    setState(() {
      _categories[ci] = cat.copyWith(files: normalized);
    });
    _mutationRev++;
    await DataManager.instance.saveResourceFileOrders(
      scopeType: 'file_shortcut',
      category: _kCategoryKey,
      parentId: catId,
      rows: [
        for (int i = 0; i < normalized.length; i++)
          {
            'file_id': normalized[i].id,
            'order_index': i,
          },
      ],
    );
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

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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
    _showSnack('파일 추가는 기타 탭에서 해주세요.');
  }

  Future<void> _onEditPressed() async {
    _showSnack('폴더는 기타 탭에서 관리하고, 파일은 카드에서 수정하세요.');
  }

  Future<void> _onDeletePressed() async {
    _showSnack('폴더는 기타 탭에서 관리하고, 파일은 카드에서 삭제하세요.');
  }

  Future<void> _onAddFilePressed() async {
    _showSnack('파일 추가는 기타 탭에서 해주세요.');
  }

  Future<void> _openCategoryPicker() async {
    if (_categories.isEmpty) {
      _showSnack('기타 탭에서 폴더를 먼저 만들어 주세요.');
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
    final files = cat?.filesOrEmpty ?? const <_FsFile>[];

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
            label: '폴더',
            valueText: bootEmpty
                ? '불러오는 중...'
                : (hasCategory
                    ? (cat!.name.trim().isNotEmpty ? cat!.name : '불러오는 중...')
                    : '폴더 없음 (기타 탭에서 추가)'),
            selected: hasCategory,
            onTap: (_loading || bootEmpty) ? null : () => unawaited(_openCategoryPicker()),
          ),
          const SizedBox(height: 16),
          const Divider(height: 1, color: Color(0x22FFFFFF)),
          const SizedBox(height: 16),
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
                    title: '등록된 폴더가 없습니다.',
                    subtitle: '기타 탭에서 폴더를 먼저 만들어 주세요.',
                  )
                : (files.isEmpty
                    ? const _EmptyState(
                        icon: Icons.insert_drive_file_outlined,
                        title: '등록된 파일이 없습니다.',
                        subtitle: '',
                      )
                    : Scrollbar(
                        controller: _scrollCtrl,
                        thumbVisibility: true,
                        child: ReorderableListView.builder(
                          scrollController: _scrollCtrl,
                          buildDefaultDragHandles: false,
                          proxyDecorator: _rsReorderProxyDecorator,
                          itemCount: files.length,
                          onReorder: (oldIndex, newIndex) => unawaited(_onReorderFiles(oldIndex: oldIndex, newIndex: newIndex)),
                          itemBuilder: (context, index) {
                            final f = files[index];
                            return Padding(
                              key: ValueKey(f.id),
                              padding: EdgeInsets.only(bottom: (index == files.length - 1) ? 0 : 8),
                              child: ReorderableDelayedDragStartListener(
                                index: index,
                                child: SizedBox(
                                  width: double.infinity,
                                  child: _FileCard(
                                    file: f,
                                    dialogContext: _dlgCtx,
                                    onPrint: _openPrintDialogForPath,
                                    onRename: () => unawaited(_renameFile(fileId: f.id)),
                                    onDelete: () => unawaited(_deleteFile(fileId: f.id)),
                                  ),
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

  String label() {
    switch (this) {
      case _FsFileKind.pdf:
        return 'PDF';
      case _FsFileKind.hwp:
        return 'HWP';
      case _FsFileKind.other:
        return '기타';
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
  final Map<_FsFileKind, String> links;
  final int order;

  const _FsFile({
    required this.id,
    required this.name,
    required this.links,
    required this.order,
  });

  _FsFile copyWith({
    String? id,
    String? name,
    Map<_FsFileKind, String>? links,
    int? order,
  }) {
    return _FsFile(
      id: id ?? this.id,
      name: name ?? this.name,
      links: links ?? this.links,
      order: order ?? this.order,
    );
  }

  List<_FsFileKind> get availableKinds => links.keys.toList()
    ..sort((a, b) => a.label().compareTo(b.label()));

  _FsFileKind get defaultKind {
    if (links.containsKey(_FsFileKind.pdf)) return _FsFileKind.pdf;
    if (links.containsKey(_FsFileKind.hwp)) return _FsFileKind.hwp;
    return _FsFileKind.other;
  }

  String pathFor(_FsFileKind kind) => (links[kind] ?? '').trim();
}

class _FsCategory {
  final String id;
  String name;
  int order;
  List<_FsFile>? files;

  _FsCategory({
    required this.id,
    required this.name,
    required this.order,
    List<_FsFile>? files,
  }) : files = files ?? <_FsFile>[];

  List<_FsFile> get filesOrEmpty => files ?? const <_FsFile>[];

  _FsCategory copyWith({
    String? id,
    String? name,
    int? order,
    List<_FsFile>? files,
  }) {
    return _FsCategory(
      id: id ?? this.id,
      name: name ?? this.name,
      order: order ?? this.order,
      files: files ?? this.filesOrEmpty,
    );
  }
}

class _FsExternalFolderRow {
  final String id;
  final String name;
  final String parentId;
  final int order;
  const _FsExternalFolderRow({
    required this.id,
    required this.name,
    required this.parentId,
    required this.order,
  });
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
          // 폴더 행을 누르면 폴더 선택
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
  late _FsFileKind _activeKind;
  final TextEditingController _pageRangeCtrl = ImeAwareTextEditingController();
  final GlobalKey _paperAnchorKey = GlobalKey();
  final GlobalKey _kindAnchorKey = GlobalKey();
  OverlayEntry? _paperMenuEntry;
  Completer<_FsPaperSize?>? _paperMenuCompleter;
  OverlayEntry? _kindMenuEntry;
  Completer<_FsFileKind?>? _kindMenuCompleter;

  @override
  void initState() {
    super.initState();
    _activeKind = widget.file.defaultKind;
  }

  @override
  void didUpdateWidget(covariant _FileCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final available = widget.file.availableKinds;
    if (available.isEmpty) {
      _activeKind = _FsFileKind.other;
      return;
    }
    if (!available.contains(_activeKind)) {
      _activeKind = widget.file.defaultKind;
    }
  }

  List<_FsFileKind> get _availableKinds => widget.file.availableKinds;
  String get _activePath => widget.file.pathFor(_activeKind);
  bool get _hasActiveLink => _activeKind != _FsFileKind.other && _activePath.trim().isNotEmpty;
  bool get _hasMultipleKinds => _availableKinds.length > 1;

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

  void _dismissKindMenu([_FsFileKind? picked]) {
    final entry = _kindMenuEntry;
    final c = _kindMenuCompleter;
    _kindMenuEntry = null;
    _kindMenuCompleter = null;
    try {
      entry?.remove();
    } catch (_) {}
    if (c != null && !c.isCompleted) {
      c.complete(picked);
    }
  }

  @override
  void dispose() {
    _dismissKindMenu();
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

  Future<void> _openKindMenu() async {
    if (_printing || !_hasMultipleKinds) return;
    final anchorCtx = _kindAnchorKey.currentContext;
    if (anchorCtx == null) return;
    if (_kindMenuEntry != null) {
      _dismissKindMenu();
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

    final completer = Completer<_FsFileKind?>();
    _kindMenuCompleter = completer;

    const gap = 8.0;
    const itemHeight = 40.0;

    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) {
        final overlaySize = overlayBox.size;
        final menuWidth = math.max(anchorRect.width, 140.0);
        final menuHeight = itemHeight * _availableKinds.length;

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
                onTap: _dismissKindMenu,
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
                    for (final v in _availableKinds)
                      InkWell(
                        onTap: () => _dismissKindMenu(v),
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
                                      color: v == _activeKind ? _rsText : _rsTextSub,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ),
                                if (v == _activeKind)
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

    _kindMenuEntry = entry;
    overlayState.insert(entry);

    final picked = await completer.future;
    if (picked == null || picked == _activeKind) return;
    if (!mounted) return;
    setState(() {
      _activeKind = picked;
      _pageRangeCtrl.clear();
      _paperSize = _FsPaperSize.followFile;
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
    final srcPath = _activePath.trim();
    if (srcPath.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('연결된 파일이 없습니다.')));
      }
      return;
    }
    setState(() => _printing = true);
    try {
      unawaited(_cleanupOldPrintTemps());
      // HWP는 환경별로 자동화(숨김/키보드) 방식이 쉽게 깨질 수 있어,
      // 가장 안정적인 방식(Windows Shell Verb "Print")으로 위임한다.
      // -> "파일은 안 열리고, 인쇄 진행/대화창만 뜬 뒤 자동 인쇄"가 이 경로에서 동작하는 경우가 많다.
      if (_activeKind == _FsFileKind.hwp) {
        await _printHwpShellVerbBestEffort(path: srcPath, paper: _paperSize);
        return;
      }
      String pathToPrint = srcPath;
      String? tempToDelete;
      // 용지 크기 지정은 PDF에서만 적용(새 PDF 생성)
      if (_activeKind == _FsFileKind.pdf) {
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
    const double _controlHeight = 35;

    Widget buildKindPicker() {
      if (_availableKinds.isEmpty) {
        return const SizedBox.shrink();
      }
      final label = _activeKind.label();
      final chip = DecoratedBox(
        decoration: BoxDecoration(
          color: _rsPanelBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.transparent),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: const TextStyle(color: _rsTextSub, fontSize: 13, fontWeight: FontWeight.w900),
              ),
              if (_hasMultipleKinds) ...[
                const SizedBox(width: 2),
                const Icon(Icons.expand_more, size: 16, color: _rsTextSub),
              ],
            ],
          ),
        ),
      );
      if (!_hasMultipleKinds || _printing) return chip;
      return SizedBox(
        height: _controlHeight,
        child: InkWell(
          key: _kindAnchorKey,
          onTap: _openKindMenu,
          borderRadius: BorderRadius.circular(10),
          child: chip,
        ),
      );
    }

    final content = Material(
      color: Colors.transparent,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 12, 0, 5),
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
                  child: InkWell(
                    onTap: () {
                      if (_dx != 0) {
                        _close();
                        return;
                      }
                      final p = _activePath.trim();
                      if (p.isEmpty) return;
                      unawaited(OpenFilex.open(p));
                    },
                    child: Text(
                      file.name,
                      style: const TextStyle(color: _rsText, fontSize: 15, fontWeight: FontWeight.w900),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                buildKindPicker(),
              ],
            ),
            const SizedBox(height: 13),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: (_activeKind == _FsFileKind.hwp) ? '바로 인쇄' : '인쇄',
                  onPressed: (_printing || !_hasActiveLink) ? null : () => unawaited(_printNow()),
                  icon: const Icon(Icons.print_outlined, color: Colors.white70, size: 20),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                ),
                if (_activeKind == _FsFileKind.pdf && _hasActiveLink) ...[
                  const Spacer(),
                  SizedBox(
                    height: _controlHeight,
                    child: InkWell(
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
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 120,
                    height: _controlHeight,
                    child: TextField(
                      controller: _pageRangeCtrl,
                      enabled: !_printing,
                      minLines: 1,
                      maxLines: 1,
                      textAlignVertical: TextAlignVertical.center,
                      style: const TextStyle(color: _rsText, fontSize: 12, fontWeight: FontWeight.w700),
                      decoration: InputDecoration(
                        hintText: '페이지 (예: 10-15)',
                        hintStyle: const TextStyle(color: _rsTextSub, fontSize: 11),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
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
                        isDense: false,
                      ),
                    ),
                  ),
                ],
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
          if (subtitle.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: const TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.w600, height: 1.3),
              textAlign: TextAlign.center,
            ),
          ],
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
      title: const Text('폴더 선택', style: TextStyle(color: _rsText, fontWeight: FontWeight.w900)),
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


