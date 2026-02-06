import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:postgrest/postgrest.dart' show PostgrestException;

import 'academy_db.dart';
import 'runtime_flags.dart';
import 'tag_preset_service.dart';
import 'tenant_service.dart';

class ResourceService {
  ResourceService._internal();
  static final ResourceService instance = ResourceService._internal();

  static const String _resourceFileSelectBase =
      'id,parent_id:folder_id,name,url,category,order_index';
  static const String _resourceFileSelectExtended =
      'id,parent_id:folder_id,name,url,category,order_index,icon_code,icon_image_path,description,text_color,color,grade,pos_x,pos_y,width,height';

  bool _resourceFilesExtendedColumnsAvailable = true;
  bool _resourceFileOrdersAvailable = true;

  String _scopeTypeForCategory(String category) {
    return category == 'file_shortcut' ? 'file_shortcut' : 'resources';
  }

  bool _isMissingColumnError(Object e) {
    if (e is PostgrestException) {
      return e.code == '42703' || e.code == 'PGRST204';
    }
    final msg = e.toString();
    return msg.contains('does not exist') || msg.contains('schema cache');
  }

  bool _isMissingTableError(Object e) {
    if (e is PostgrestException) {
      return e.code == '42P01' || e.code == 'PGRST106';
    }
    final msg = e.toString();
    return msg.contains('does not exist') && msg.contains('resource_file_orders');
  }

  Map<String, dynamic> _buildResourceFileUpsert(
    Map<String, dynamic> row, {
    required String academyId,
    required bool extended,
  }) {
    final up = <String, dynamic>{
      'id': row['id'],
      'academy_id': academyId,
    };
    if (row.containsKey('parent_id')) up['folder_id'] = row['parent_id'];
    if (row.containsKey('name')) up['name'] = row['name'];
    if (row.containsKey('url')) up['url'] = row['url'];
    if (row.containsKey('category')) up['category'] = row['category'];
    if (row.containsKey('order_index')) up['order_index'] = row['order_index'];
    if (extended) {
      if (row.containsKey('icon_code')) up['icon_code'] = row['icon_code'];
      if (row.containsKey('icon_image_path')) up['icon_image_path'] = row['icon_image_path'];
      if (row.containsKey('description')) up['description'] = row['description'];
      if (row.containsKey('text_color')) up['text_color'] = row['text_color'];
      if (row.containsKey('color')) up['color'] = row['color'];
      if (row.containsKey('grade')) up['grade'] = row['grade'];
      if (row.containsKey('pos_x')) up['pos_x'] = row['pos_x'];
      if (row.containsKey('pos_y')) up['pos_y'] = row['pos_y'];
      if (row.containsKey('width')) up['width'] = row['width'];
      if (row.containsKey('height')) up['height'] = row['height'];
    }
    return up;
  }

  List<Map<String, dynamic>> _mergeResourceFileRows(
    List<Map<String, dynamic>> serverRows,
    List<Map<String, dynamic>> localRows,
  ) {
    final localById = <String, Map<String, dynamic>>{};
    for (final r in localRows) {
      final id = (r['id'] as String?) ?? '';
      if (id.isNotEmpty) localById[id] = r;
    }
    const extendedKeys = [
      'icon_code',
      'icon_image_path',
      'description',
      'text_color',
      'color',
      'grade',
      'pos_x',
      'pos_y',
      'width',
      'height',
    ];
    for (final row in serverRows) {
      final id = (row['id'] as String?) ?? '';
      final local = localById[id];
      if (local == null) continue;
      for (final k in extendedKeys) {
        if (!row.containsKey(k) || row[k] == null) {
          row[k] = local[k];
        }
      }
    }
    return serverRows;
  }

  Future<List<Map<String, dynamic>>> _applyOrderOverrides(
    List<Map<String, dynamic>> rows,
    String category,
  ) async {
    if (rows.isEmpty) return rows;
    final orders = await _loadOrderOverrides(category);
    if (orders.isEmpty) return rows;
    final orderByKey = <String, int>{};
    for (final o in orders) {
      final fileId = (o['file_id'] as String?) ?? '';
      if (fileId.isEmpty) continue;
      final parent = (o['parent_id'] as String?) ?? '';
      final order = (o['order_index'] as int?) ?? 0;
      orderByKey['$fileId|$parent'] = order;
    }
    for (final row in rows) {
      final fileId = (row['id'] as String?) ?? '';
      if (fileId.isEmpty) continue;
      final parent = (row['parent_id'] as String?) ?? '';
      final key = '$fileId|$parent';
      if (orderByKey.containsKey(key)) {
        row['order_index'] = orderByKey[key];
      }
    }
    return rows;
  }

  Future<List<Map<String, dynamic>>> _loadOrderOverrides(String category) async {
    final scopeType = _scopeTypeForCategory(category);
    if (TagPresetService.preferSupabaseRead && _resourceFileOrdersAvailable) {
      try {
        final academyId =
            await TenantService.instance.getActiveAcademyId() ??
                await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        final data = await supa
            .from('resource_file_orders')
            .select('file_id,parent_id,order_index')
            .match({
              'academy_id': academyId,
              'scope_type': scopeType,
              'category': category,
            });
        return (data as List).cast<Map<String, dynamic>>();
      } catch (e, st) {
        if (_isMissingTableError(e)) {
          _resourceFileOrdersAvailable = false;
        } else {
          print('[RES][file order load] supabase failed: $e\n$st');
        }
      }
    }
    return await AcademyDbService.instance.loadResourceFileOrders(
      scopeType: scopeType,
      category: category,
    );
  }

  // ======== RESOURCES (FOLDERS/FILES) ========
  Future<void> saveResourceFolders(List<Map<String, dynamic>> rows) async {
    await AcademyDbService.instance.saveResourceFolders(rows);
    if (TagPresetService.dualWrite) {
      try {
        final academyId =
            await TenantService.instance.getActiveAcademyId() ??
                await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        await supa.from('resource_folders').delete().eq('academy_id', academyId);
        if (rows.isNotEmpty) {
          final up = rows
              .map((r) => {
                    'id': r['id'],
                    'academy_id': academyId,
                    'name': r['name'],
                    'parent_id': r['parent_id'],
                    'order_index': r['order_index'],
                    'category': r['category'],
                  })
              .toList();
          await supa.from('resource_folders').insert(up);
        }
      } catch (_) {}
    }
  }

  Future<void> saveResourceFoldersForCategory(
    String category,
    List<Map<String, dynamic>> rows,
  ) async {
    await AcademyDbService.instance.saveResourceFoldersForCategory(category, rows);
    if (TagPresetService.dualWrite) {
      try {
        final academyId =
            await TenantService.instance.getActiveAcademyId() ??
                await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        await supa.from('resource_folders').delete().match({
          'academy_id': academyId,
          'category': category,
        });
        if (rows.isNotEmpty) {
          final up = rows.map((raw) {
            final r = Map<String, dynamic>.from(raw);
            return {
              'id': r['id'],
              'academy_id': academyId,
              'name': r['name'],
              'parent_id': r['parent_id'],
              'order_index': r['order_index'],
              'category': category,
            };
          }).toList();
          await supa.from('resource_folders').insert(up);
        }
      } catch (_) {}
    }
  }

  Future<List<Map<String, dynamic>>> loadResourceFolders() async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId =
            await TenantService.instance.getActiveAcademyId() ??
                await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        final data = await supa
            .from('resource_folders')
            .select('id,name,parent_id,order_index,category')
            .eq('academy_id', academyId)
            .order('order_index');
        return (data as List).cast<Map<String, dynamic>>();
      } catch (e, st) {
        print('[RES][folders] server load failed: $e\n$st');
        if (RuntimeFlags.serverOnly) {
          return <Map<String, dynamic>>[];
        }
      }
    }
    return await AcademyDbService.instance.loadResourceFolders();
  }

  Future<List<Map<String, dynamic>>> loadResourceFoldersForCategory(
    String category,
  ) async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId =
            await TenantService.instance.getActiveAcademyId() ??
                await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        List<dynamic> data;
        if (category == 'textbook') {
          data = await supa
              .from('resource_folders')
              .select('id,name,parent_id,order_index,category')
              .eq('academy_id', academyId)
              .or('category.is.null,category.eq.textbook')
              .order('order_index');
        } else {
          data = await supa
              .from('resource_folders')
              .select('id,name,parent_id,order_index,category')
              .match({'academy_id': academyId, 'category': category})
              .order('order_index');
        }
        return (data as List).cast<Map<String, dynamic>>();
      } catch (e, st) {
        print('[RES][foldersByCat] server load failed: $e\n$st');
        if (RuntimeFlags.serverOnly) {
          return <Map<String, dynamic>>[];
        }
      }
    }
    return await AcademyDbService.instance.loadResourceFoldersForCategory(category);
  }

  Future<void> saveResourceFile(Map<String, dynamic> row) async {
    await AcademyDbService.instance.saveResourceFile(row);
    if (TagPresetService.dualWrite) {
      try {
        final academyId =
            await TenantService.instance.getActiveAcademyId() ??
                await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        final up = _buildResourceFileUpsert(
          row,
          academyId: academyId,
          extended: _resourceFilesExtendedColumnsAvailable,
        );
        try {
          await supa.from('resource_files').upsert(up, onConflict: 'id');
        } on PostgrestException catch (e) {
          if (_resourceFilesExtendedColumnsAvailable && _isMissingColumnError(e)) {
            _resourceFilesExtendedColumnsAvailable = false;
            final fallback = _buildResourceFileUpsert(
              row,
              academyId: academyId,
              extended: false,
            );
            await supa.from('resource_files').upsert(fallback, onConflict: 'id');
          } else {
            rethrow;
          }
        }
      } catch (e, st) {
        print('[RES][file save] supabase upsert failed: $e\n$st');
      }
    }
  }

  Future<void> saveResourceFileWithCategory(
    Map<String, dynamic> row,
    String category,
  ) async {
    final copy = Map<String, dynamic>.from(row);
    copy['category'] = category;
    await saveResourceFile(copy);
  }

  Future<List<Map<String, dynamic>>> loadResourceFiles() async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId =
            await TenantService.instance.getActiveAcademyId() ??
                await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        List<dynamic> data;
        bool usedExtended = _resourceFilesExtendedColumnsAvailable;
        try {
          data = await supa
              .from('resource_files')
              .select(usedExtended ? _resourceFileSelectExtended : _resourceFileSelectBase)
              .eq('academy_id', academyId)
              .order('order_index');
        } on PostgrestException catch (e) {
          if (usedExtended && _isMissingColumnError(e)) {
            _resourceFilesExtendedColumnsAvailable = false;
            usedExtended = false;
            data = await supa
                .from('resource_files')
                .select(_resourceFileSelectBase)
                .eq('academy_id', academyId)
                .order('order_index');
          } else {
            rethrow;
          }
        }
        final rows = (data as List).cast<Map<String, dynamic>>();
        if (!usedExtended && !RuntimeFlags.serverOnly) {
          final local = await AcademyDbService.instance.loadResourceFiles();
          return _mergeResourceFileRows(rows, local);
        }
        return rows;
      } catch (e, st) {
        print('[RES][files] server load failed: $e\n$st');
        if (RuntimeFlags.serverOnly) {
          return <Map<String, dynamic>>[];
        }
      }
    }
    return await AcademyDbService.instance.loadResourceFiles();
  }

  Future<List<Map<String, dynamic>>> loadResourceFilesForCategory(
    String category,
  ) async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId =
            await TenantService.instance.getActiveAcademyId() ??
                await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        List<dynamic> data;
        bool usedExtended = _resourceFilesExtendedColumnsAvailable;
        Future<List<dynamic>> runSelect(String cols) async {
          if (category == 'textbook') {
            return await supa
                .from('resource_files')
                .select(cols)
                .eq('academy_id', academyId)
                .or('category.is.null,category.eq.textbook')
                .order('order_index');
          }
          return await supa
              .from('resource_files')
              .select(cols)
              .match({'academy_id': academyId, 'category': category})
              .order('order_index');
        }

        try {
          data = await runSelect(usedExtended ? _resourceFileSelectExtended : _resourceFileSelectBase);
        } on PostgrestException catch (e) {
          if (usedExtended && _isMissingColumnError(e)) {
            _resourceFilesExtendedColumnsAvailable = false;
            usedExtended = false;
            data = await runSelect(_resourceFileSelectBase);
          } else {
            rethrow;
          }
        }
        var rows = (data as List).cast<Map<String, dynamic>>();
        if (!RuntimeFlags.serverOnly) {
          final local = await AcademyDbService.instance.loadResourceFilesForCategory(category);
          if (local.isNotEmpty) {
            rows = _mergeResourceFileRows(rows, local);
          }
        }
        return await _applyOrderOverrides(rows, category);
      } catch (e, st) {
        print('[RES][filesByCat] server load failed: $e\n$st');
        if (RuntimeFlags.serverOnly) {
          return <Map<String, dynamic>>[];
        }
      }
    }
    final rows = await AcademyDbService.instance.loadResourceFilesForCategory(category);
    return await _applyOrderOverrides(rows, category);
  }

  Future<void> saveResourceFileOrders({
    required String scopeType,
    required String category,
    required String? parentId,
    required List<Map<String, dynamic>> rows,
  }) async {
    await AcademyDbService.instance.saveResourceFileOrders(
      scopeType: scopeType,
      category: category,
      parentId: parentId,
      rows: rows,
    );
    if (TagPresetService.dualWrite && _resourceFileOrdersAvailable) {
      try {
        final academyId =
            await TenantService.instance.getActiveAcademyId() ??
                await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        final parent = (parentId ?? '').trim();
        final up = rows
            .map((r) => {
                  'academy_id': academyId,
                  'scope_type': scopeType,
                  'category': category,
                  'parent_id': parent,
                  'file_id': r['file_id'],
                  'order_index': r['order_index'],
                })
            .toList();
        if (up.isNotEmpty) {
          await supa.from('resource_file_orders').upsert(
                up,
                onConflict: 'academy_id,scope_type,category,parent_id,file_id',
              );
        }
      } catch (e, st) {
        if (_isMissingTableError(e)) {
          _resourceFileOrdersAvailable = false;
        } else {
          print('[RES][file order save] supabase upsert failed: $e\n$st');
        }
      }
    }
  }

  Future<void> saveResourceFileLinks(String fileId, Map<String, String> links) async {
    await AcademyDbService.instance.saveResourceFileLinks(fileId, links);
    if (TagPresetService.dualWrite) {
      try {
        final academyId =
            await TenantService.instance.getActiveAcademyId() ??
                await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        await supa.from('resource_file_links').delete().match({
          'academy_id': academyId,
          'file_id': fileId,
        });
        if (links.isNotEmpty) {
          final rows = links.entries
              .where((e) => e.key.trim().isNotEmpty && e.value.trim().isNotEmpty)
              .map((e) => {
                    'academy_id': academyId,
                    'file_id': fileId,
                    'grade': e.key.trim(),
                    'url': e.value.trim(),
                  })
              .toList();
          if (rows.isNotEmpty) {
            await supa.from('resource_file_links').insert(rows);
          }
        }
      } catch (e, st) {
        print('[RES][links save] supabase write failed: $e\n$st');
      }
    }
  }

  Future<Map<String, String>> loadResourceFileLinks(String fileId) async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId =
            await TenantService.instance.getActiveAcademyId() ??
                await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        final data = await supa
            .from('resource_file_links')
            .select('grade,url')
            .match({'academy_id': academyId, 'file_id': fileId});
        final Map<String, String> result = {};
        for (final r in (data as List).cast<Map<String, dynamic>>()) {
          final grade = (r['grade'] as String?)?.trim() ?? '';
          final url = (r['url'] as String?)?.trim() ?? '';
          if (grade.isNotEmpty && url.isNotEmpty) result[grade] = url;
        }
        return result;
      } catch (e, st) {
        print('[RES][links load] server load failed: $e\n$st');
        if (RuntimeFlags.serverOnly) {
          return <String, String>{};
        }
      }
    }
    return await AcademyDbService.instance.loadResourceFileLinks(fileId);
  }

  Future<void> deleteResourceFile(String fileId) async {
    await AcademyDbService.instance.deleteResourceFileLinksByFileId(fileId);
    await AcademyDbService.instance.deleteResourceFileOrdersByFileId(fileId);
    await AcademyDbService.instance.deleteResourceFile(fileId);
    if (TagPresetService.dualWrite) {
      try {
        final supa = Supabase.instance.client;
        final academyId =
            await TenantService.instance.getActiveAcademyId() ??
                await TenantService.instance.ensureActiveAcademy();
        await supa.from('resource_files').delete().eq('id', fileId);
        await supa.from('resource_file_orders').delete().match({
          'academy_id': academyId,
          'file_id': fileId,
        });
      } catch (_) {}
    }
  }

  // ======== RESOURCE FAVORITES ========
  Future<Set<String>> loadResourceFavorites() async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId =
            await TenantService.instance.getActiveAcademyId() ??
                await TenantService.instance.ensureActiveAcademy();
        final userId = Supabase.instance.client.auth.currentUser?.id;
        if (userId != null) {
          final data = await Supabase.instance.client
              .from('resource_favorites')
              .select('file_id')
              .match({'academy_id': academyId, 'user_id': userId});
          final set = (data as List).map((r) => (r['file_id'] as String)).toSet();
          return set;
        }
      } catch (e, st) {
        print('[RES][favorites load] server load failed: $e\n$st');
        if (RuntimeFlags.serverOnly) {
          return <String>{};
        }
      }
    }
    final dbClient = await AcademyDbService.instance.db;
    await AcademyDbService.instance.ensureResourceTables();
    final rows = await dbClient.query('resource_favorites');
    return rows.map((r) => (r['file_id'] as String)).toSet();
  }

  Future<void> addResourceFavorite(String fileId) async {
    final dbClient = await AcademyDbService.instance.db;
    await AcademyDbService.instance.ensureResourceTables();
    await dbClient.insert(
      'resource_favorites',
      {'file_id': fileId},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    if (TagPresetService.dualWrite) {
      try {
        final academyId =
            await TenantService.instance.getActiveAcademyId() ??
                await TenantService.instance.ensureActiveAcademy();
        final userId = Supabase.instance.client.auth.currentUser?.id;
        if (userId != null) {
          await Supabase.instance.client.from('resource_favorites').upsert({
            'academy_id': academyId,
            'file_id': fileId,
            'user_id': userId,
          });
        }
      } catch (_) {}
    }
  }

  Future<void> removeResourceFavorite(String fileId) async {
    final dbClient = await AcademyDbService.instance.db;
    await AcademyDbService.instance.ensureResourceTables();
    await dbClient.delete('resource_favorites', where: 'file_id = ?', whereArgs: [fileId]);
    if (TagPresetService.dualWrite) {
      try {
        final academyId =
            await TenantService.instance.getActiveAcademyId() ??
                await TenantService.instance.ensureActiveAcademy();
        final userId = Supabase.instance.client.auth.currentUser?.id;
        if (userId != null) {
          await Supabase.instance.client.from('resource_favorites').delete().match({
            'academy_id': academyId,
            'file_id': fileId,
            'user_id': userId,
          });
        }
      } catch (_) {}
    }
  }

  // ======== RESOURCE FILE BOOKMARKS ========
  Future<List<Map<String, dynamic>>> loadResourceFileBookmarks(String fileId) async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId =
            await TenantService.instance.getActiveAcademyId() ??
                await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        final data = await supa
            .from('resource_file_bookmarks')
            .select('name,description,path,order_index')
            .match({'academy_id': academyId, 'file_id': fileId})
            .order('order_index');
        return (data as List).cast<Map<String, dynamic>>();
      } catch (e, st) {
        print('[RES][bookmarks load] server load failed: $e\n$st');
        if (RuntimeFlags.serverOnly) {
          return <Map<String, dynamic>>[];
        }
      }
    }
    final dbClient = await AcademyDbService.instance.db;
    await AcademyDbService.instance.ensureResourceTables();
    return await dbClient.query(
      'resource_file_bookmarks',
      where: 'file_id = ?',
      whereArgs: [fileId],
      orderBy: 'order_index ASC',
    );
  }

  Future<void> saveResourceFileBookmarks(
    String fileId,
    List<Map<String, dynamic>> items,
  ) async {
    final dbClient = await AcademyDbService.instance.db;
    await AcademyDbService.instance.ensureResourceTables();
    await dbClient.transaction((txn) async {
      await txn.delete('resource_file_bookmarks', where: 'file_id = ?', whereArgs: [fileId]);
      for (int i = 0; i < items.length; i++) {
        final it = Map<String, dynamic>.from(items[i]);
        it['file_id'] = fileId;
        it['order_index'] = i;
        await txn.insert('resource_file_bookmarks', it);
      }
    });
    if (TagPresetService.dualWrite) {
      try {
        final academyId =
            await TenantService.instance.getActiveAcademyId() ??
                await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        await supa.from('resource_file_bookmarks').delete().match({
          'academy_id': academyId,
          'file_id': fileId,
        });
        if (items.isNotEmpty) {
          final rows = <Map<String, dynamic>>[];
          for (int i = 0; i < items.length; i++) {
            final it = Map<String, dynamic>.from(items[i]);
            rows.add({
              'academy_id': academyId,
              'file_id': fileId,
              'name': it['name'],
              'description': it['description'],
              'path': it['path'],
              'order_index': i,
            });
          }
          if (rows.isNotEmpty) {
            await supa.from('resource_file_bookmarks').insert(rows);
          }
        }
      } catch (_) {}
    }
  }

  // ======== RESOURCE GRADES (학년 목록/순서) ========
  Future<List<Map<String, dynamic>>> getResourceGrades() async {
    return await AcademyDbService.instance.getResourceGrades();
  }

  Future<void> saveResourceGrades(List<String> names) async {
    await AcademyDbService.instance.saveResourceGrades(names);
  }

  // ======== RESOURCE GRADE ICONS ========
  Future<Map<String, int>> getResourceGradeIcons() async {
    return await AcademyDbService.instance.getResourceGradeIcons();
  }

  Future<void> setResourceGradeIcon(String name, int icon) async {
    await AcademyDbService.instance.setResourceGradeIcon(name, icon);
  }

  Future<void> deleteResourceGradeIcon(String name) async {
    await AcademyDbService.instance.deleteResourceGradeIcon(name);
  }
}




























