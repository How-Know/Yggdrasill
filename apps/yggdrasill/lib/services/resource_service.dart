import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'academy_db.dart';
import 'runtime_flags.dart';
import 'tag_preset_service.dart';
import 'tenant_service.dart';

class ResourceService {
  ResourceService._internal();
  static final ResourceService instance = ResourceService._internal();

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
        final up = {
          'id': row['id'],
          'academy_id': academyId,
          'folder_id': row['parent_id'],
          'name': row['name'],
          'url': row['url'],
          'category': row['category'],
          'order_index': row['order_index'],
        };
        await supa.from('resource_files').upsert(up, onConflict: 'id');
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
        final data = await supa
            .from('resource_files')
            .select('id,parent_id:folder_id,name,url,category,order_index')
            .eq('academy_id', academyId)
            .order('order_index');
        return (data as List).cast<Map<String, dynamic>>();
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
        if (category == 'textbook') {
          data = await supa
              .from('resource_files')
              .select('id,parent_id:folder_id,name,url,category,order_index')
              .eq('academy_id', academyId)
              .or('category.is.null,category.eq.textbook')
              .order('order_index');
        } else {
          data = await supa
              .from('resource_files')
              .select('id,parent_id:folder_id,name,url,category,order_index')
              .match({'academy_id': academyId, 'category': category})
              .order('order_index');
        }
        return (data as List).cast<Map<String, dynamic>>();
      } catch (e, st) {
        print('[RES][filesByCat] server load failed: $e\n$st');
        if (RuntimeFlags.serverOnly) {
          return <Map<String, dynamic>>[];
        }
      }
    }
    return await AcademyDbService.instance.loadResourceFilesForCategory(category);
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
    await AcademyDbService.instance.deleteResourceFile(fileId);
    if (TagPresetService.dualWrite) {
      try {
        final supa = Supabase.instance.client;
        await supa.from('resource_files').delete().eq('id', fileId);
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



















