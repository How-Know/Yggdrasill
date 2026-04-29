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
    return msg.contains('does not exist') &&
        msg.contains('resource_file_orders');
  }

  int? _asInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
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
      if (row.containsKey('icon_image_path'))
        up['icon_image_path'] = row['icon_image_path'];
      if (row.containsKey('description'))
        up['description'] = row['description'];
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
      // 서버 folder_id(parent_id alias)가 비어 있는 경우,
      // 로컬 parent_id로 보정해서 폴더 매칭이 끊기지 않도록 한다.
      final serverParent = (row['parent_id'] as String?)?.trim() ?? '';
      final localParent = (local['parent_id'] as String?)?.trim() ?? '';
      if (serverParent.isEmpty && localParent.isNotEmpty) {
        row['parent_id'] = localParent;
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
    final parentsByFileId = <String, Set<String>>{};
    for (final o in orders) {
      final fileId = (o['file_id'] as String?) ?? '';
      if (fileId.isEmpty) continue;
      final parent = ((o['parent_id'] as String?) ?? '').trim();
      final order = (o['order_index'] as int?) ?? 0;
      orderByKey['$fileId|$parent'] = order;
      if (parent.isNotEmpty) {
        final set = parentsByFileId.putIfAbsent(fileId, () => <String>{});
        set.add(parent);
      }
    }

    var repairedParentFromOrders = 0;
    for (final row in rows) {
      final fileId = (row['id'] as String?) ?? '';
      if (fileId.isEmpty) continue;
      final currentParent = ((row['parent_id'] as String?) ?? '').trim();
      if (currentParent.isNotEmpty) continue;
      final candidates = parentsByFileId[fileId];
      if (candidates != null && candidates.length == 1) {
        row['parent_id'] = candidates.first;
        repairedParentFromOrders++;
      }
    }

    if (repairedParentFromOrders > 0) {
      print(
          '[RES][filesByCat] repaired missing parent_id via order table: $repairedParentFromOrders');
    }

    for (final row in rows) {
      final fileId = (row['id'] as String?) ?? '';
      if (fileId.isEmpty) continue;
      final parent = ((row['parent_id'] as String?) ?? '').trim();
      final key = '$fileId|$parent';
      if (orderByKey.containsKey(key)) {
        row['order_index'] = orderByKey[key];
      }
    }
    return rows;
  }

  Future<List<Map<String, dynamic>>> _loadOrderOverrides(
      String category) async {
    final scopeType = _scopeTypeForCategory(category);
    if (TagPresetService.preferSupabaseRead && _resourceFileOrdersAvailable) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ??
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
  Future<List<Map<String, dynamic>>> _loadRemoteFoldersInScope({
    required SupabaseClient supa,
    required String academyId,
    String? category,
  }) async {
    if (category == null) {
      final data = await supa
          .from('resource_folders')
          .select('id,category')
          .eq('academy_id', academyId);
      return (data as List).cast<Map<String, dynamic>>();
    }

    if (category == 'textbook') {
      // textbook scope includes legacy null/empty category rows.
      final data = await supa
          .from('resource_folders')
          .select('id,category')
          .eq('academy_id', academyId);
      return (data as List).cast<Map<String, dynamic>>().where((r) {
        final c = (r['category'] as String?)?.trim();
        return c == null || c.isEmpty || c == 'textbook';
      }).toList();
    }

    final data = await supa
        .from('resource_folders')
        .select('id')
        .match({'academy_id': academyId, 'category': category});
    return (data as List).cast<Map<String, dynamic>>();
  }

  Future<void> _syncRemoteResourceFolders({
    required SupabaseClient supa,
    required String academyId,
    required List<Map<String, dynamic>> rows,
    String? category,
  }) async {
    final existingRows = await _loadRemoteFoldersInScope(
      supa: supa,
      academyId: academyId,
      category: category,
    );
    final existingIds = existingRows
        .map((r) => (r['id'] as String?) ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();

    final up = <Map<String, dynamic>>[];
    for (final raw in rows) {
      final r = Map<String, dynamic>.from(raw);
      final id = (r['id'] as String?) ?? '';
      if (id.isEmpty) continue;
      up.add({
        'id': id,
        'academy_id': academyId,
        'name': r['name'],
        // 설명은 로컬 SQLite 에서는 v0 부터 있었지만 Supabase 에는
        // 20260425120000_resource_folders_description.sql 로 새로 추가된 컬럼이다.
        // 빈 문자열은 null 로 바꿔 공간을 낭비하지 않는다.
        'description': () {
          final raw = r['description'];
          if (raw is String) {
            final trimmed = raw.trim();
            if (trimmed.isEmpty) return null;
            return trimmed;
          }
          return null;
        }(),
        'parent_id': r['parent_id'],
        'order_index': r['order_index'],
        'category': category ?? r['category'],
      });
    }

    if (up.isNotEmpty) {
      await supa.from('resource_folders').upsert(up, onConflict: 'id');
    }

    final newIds = up
        .map((r) => (r['id'] as String?) ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
    final staleIds = existingIds.difference(newIds);
    for (final id in staleIds) {
      await supa.from('resource_folders').delete().match({
        'academy_id': academyId,
        'id': id,
      });
    }
  }

  Future<void> saveResourceFolders(List<Map<String, dynamic>> rows) async {
    await AcademyDbService.instance.saveResourceFolders(rows);
    if (TagPresetService.dualWrite) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ??
            await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        await _syncRemoteResourceFolders(
          supa: supa,
          academyId: academyId,
          rows: rows,
        );
      } catch (_) {}
    }
  }

  Future<void> saveResourceFoldersForCategory(
    String category,
    List<Map<String, dynamic>> rows,
  ) async {
    await AcademyDbService.instance
        .saveResourceFoldersForCategory(category, rows);
    if (TagPresetService.dualWrite) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ??
            await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        await _syncRemoteResourceFolders(
          supa: supa,
          academyId: academyId,
          rows: rows,
          category: category,
        );
      } catch (_) {}
    }
  }

  Future<List<Map<String, dynamic>>> loadResourceFolders() async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ??
            await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        final data = await supa
            .from('resource_folders')
            .select('id,name,description,parent_id,order_index,category')
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
        final academyId = await TenantService.instance.getActiveAcademyId() ??
            await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        List<dynamic> data;
        if (category == 'textbook') {
          data = await supa
              .from('resource_folders')
              .select('id,name,description,parent_id,order_index,category')
              .eq('academy_id', academyId)
              .or('category.is.null,category.eq.textbook')
              .order('order_index');
          if ((data as List).isEmpty) {
            final all = await supa
                .from('resource_folders')
                .select('id,name,description,parent_id,order_index,category')
                .eq('academy_id', academyId)
                .order('order_index');
            final filtered =
                (all as List).cast<Map<String, dynamic>>().where((r) {
              final c = (r['category'] as String?)?.trim();
              return c == null || c.isEmpty || c == 'textbook';
            }).toList();
            return filtered;
          }
        } else {
          data = await supa
              .from('resource_folders')
              .select('id,name,description,parent_id,order_index,category')
              .match({'academy_id': academyId, 'category': category}).order(
                  'order_index');
        }
        return (data as List).cast<Map<String, dynamic>>();
      } catch (e, st) {
        print('[RES][foldersByCat] server load failed: $e\n$st');
        if (RuntimeFlags.serverOnly) {
          return <Map<String, dynamic>>[];
        }
      }
    }
    return await AcademyDbService.instance
        .loadResourceFoldersForCategory(category);
  }

  Future<void> saveResourceFile(Map<String, dynamic> row) async {
    await AcademyDbService.instance.saveResourceFile(row);
    if (TagPresetService.dualWrite) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ??
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
          if (_resourceFilesExtendedColumnsAvailable &&
              _isMissingColumnError(e)) {
            _resourceFilesExtendedColumnsAvailable = false;
            final fallback = _buildResourceFileUpsert(
              row,
              academyId: academyId,
              extended: false,
            );
            await supa
                .from('resource_files')
                .upsert(fallback, onConflict: 'id');
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
        final academyId = await TenantService.instance.getActiveAcademyId() ??
            await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        List<dynamic> data;
        bool usedExtended = _resourceFilesExtendedColumnsAvailable;
        try {
          data = await supa
              .from('resource_files')
              .select(usedExtended
                  ? _resourceFileSelectExtended
                  : _resourceFileSelectBase)
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
        final academyId = await TenantService.instance.getActiveAcademyId() ??
            await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        List<dynamic> data;
        bool usedExtended = _resourceFilesExtendedColumnsAvailable;
        Future<List<dynamic>> runSelect(String cols) async {
          if (category == 'textbook') {
            // Textbook tab is gated by `resource_files.is_published`. The
            // column has `default true` so legacy books remain visible;
            // newly-registered books from the manager wizard start at
            // `false` and only appear after the operator flips the switch
            // in the migration pane. We treat NULL as published for
            // forward/backward compatibility with older DBs.
            return await supa
                .from('resource_files')
                .select(cols)
                .eq('academy_id', academyId)
                .or('category.is.null,category.eq.textbook')
                .or('is_published.is.null,is_published.eq.true')
                .order('order_index');
          }
          return await supa
              .from('resource_files')
              .select(cols)
              .match({'academy_id': academyId, 'category': category}).order(
                  'order_index');
        }

        try {
          data = await runSelect(usedExtended
              ? _resourceFileSelectExtended
              : _resourceFileSelectBase);
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
        if (category == 'textbook' && rows.isEmpty) {
          // legacy fallback: include empty-string category rows, still
          // respecting `is_published` so unpublished drafts stay hidden.
          final all = await supa
              .from('resource_files')
              .select(usedExtended
                  ? _resourceFileSelectExtended
                  : _resourceFileSelectBase)
              .eq('academy_id', academyId)
              .or('is_published.is.null,is_published.eq.true')
              .order('order_index');
          rows = (all as List).cast<Map<String, dynamic>>().where((r) {
            final c = (r['category'] as String?)?.trim();
            return c == null || c.isEmpty || c == 'textbook';
          }).toList();
        }
        if (!RuntimeFlags.serverOnly) {
          final local = await AcademyDbService.instance
              .loadResourceFilesForCategory(category);
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
    final rows =
        await AcademyDbService.instance.loadResourceFilesForCategory(category);
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
        final academyId = await TenantService.instance.getActiveAcademyId() ??
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

  Future<void> saveResourceFileLinks(
      String fileId, Map<String, String> links) async {
    await AcademyDbService.instance.saveResourceFileLinks(fileId, links);
    if (TagPresetService.dualWrite) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ??
            await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        await supa.from('resource_file_links').delete().match({
          'academy_id': academyId,
          'file_id': fileId,
        });
        if (links.isNotEmpty) {
          final rows = links.entries
              .where(
                  (e) => e.key.trim().isNotEmpty && e.value.trim().isNotEmpty)
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
        final academyId = await TenantService.instance.getActiveAcademyId() ??
            await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        final data = await supa
            .from('resource_file_links')
            .select('grade,url,storage_key,migration_status')
            .match({'academy_id': academyId, 'file_id': fileId});
        final Map<String, String> result = {};
        for (final r in (data as List).cast<Map<String, dynamic>>()) {
          final grade = (r['grade'] as String?)?.trim() ?? '';
          final url = (r['url'] as String?)?.trim() ?? '';
          final storageKey = (r['storage_key'] as String?)?.trim() ?? '';
          final migrationStatus =
              (r['migration_status'] as String?)?.trim() ?? '';
          if (grade.isEmpty) continue;
          if (url.isNotEmpty) {
            result[grade] = url;
          } else if (storageKey.isNotEmpty &&
              (migrationStatus == 'dual' || migrationStatus == 'migrated')) {
            result[grade] = 'storage://textbook/$storageKey';
          }
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

  // ======== FLOW <-> TEXTBOOK LINKS ========
  Future<List<Map<String, dynamic>>> loadTextbooksWithMetadata() async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;

      final metadataRows = await supa
          .from('textbook_metadata')
          .select('book_id,grade_label,page_offset,payload')
          .eq('academy_id', academyId);

      final textbookFiles = await loadResourceFilesForCategory('textbook');
      final Map<String, Map<String, dynamic>> fileById =
          <String, Map<String, dynamic>>{};
      for (final row in textbookFiles) {
        final id = (row['id'] as String?) ?? '';
        if (id.isEmpty) continue;
        fileById[id] = row;
      }

      final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
      for (final row
          in (metadataRows as List<dynamic>).cast<Map<String, dynamic>>()) {
        final bookId = (row['book_id'] as String?) ?? '';
        final gradeLabel = (row['grade_label'] as String?)?.trim() ?? '';
        if (bookId.isEmpty || gradeLabel.isEmpty) continue;
        final file = fileById[bookId];
        if (file == null) continue;

        final payload = row['payload'];
        final pageOffset = _asInt(row['page_offset']);
        final bool hasPayload = payload is Map && payload.isNotEmpty;
        final bool hasMetadata = hasPayload || pageOffset != null;
        if (!hasMetadata) continue;

        out.add({
          'book_id': bookId,
          'book_name': (file['name'] as String?)?.trim() ?? '(이름 없음)',
          'grade_label': gradeLabel,
          'page_offset': pageOffset,
          'payload': payload,
        });
      }

      out.sort((a, b) {
        final an = (a['book_name'] as String?) ?? '';
        final bn = (b['book_name'] as String?) ?? '';
        final byName = an.compareTo(bn);
        if (byName != 0) return byName;
        final ag = (a['grade_label'] as String?) ?? '';
        final bg = (b['grade_label'] as String?) ?? '';
        return ag.compareTo(bg);
      });
      return out;
    } catch (e, st) {
      print('[RES][textbooksWithMetadata] load failed: $e\n$st');
      return <Map<String, dynamic>>[];
    }
  }

  Future<List<Map<String, dynamic>>> loadFlowTextbookLinks(
      String flowId) async {
    if (flowId.trim().isEmpty) return <Map<String, dynamic>>[];
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      try {
        final rows = await supa
            .from('flow_textbook_links')
            .select(
                'book_id,grade_label,order_index,resource_files(name,category)')
            .match({'academy_id': academyId, 'flow_id': flowId}).order(
                'order_index');
        final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
        for (final row
            in (rows as List<dynamic>).cast<Map<String, dynamic>>()) {
          final bookId = (row['book_id'] as String?) ?? '';
          final gradeLabel = (row['grade_label'] as String?)?.trim() ?? '';
          if (bookId.isEmpty || gradeLabel.isEmpty) continue;
          final info = row['resource_files'];
          final file = info is Map
              ? Map<String, dynamic>.from(info)
              : const <String, dynamic>{};
          final category = (file['category'] as String?)?.trim();
          if (category != null &&
              category.isNotEmpty &&
              category != 'textbook') {
            continue;
          }
          out.add({
            'book_id': bookId,
            'grade_label': gradeLabel,
            'order_index': _asInt(row['order_index']) ?? 0,
            'book_name': (file['name'] as String?)?.trim() ?? '',
          });
        }
        return out;
      } catch (_) {
        final rows = await supa
            .from('flow_textbook_links')
            .select('book_id,grade_label,order_index')
            .match({'academy_id': academyId, 'flow_id': flowId}).order(
                'order_index');
        final textbookFiles = await loadResourceFilesForCategory('textbook');
        final Map<String, String> nameById = <String, String>{
          for (final row in textbookFiles)
            if (((row['id'] as String?) ?? '').isNotEmpty)
              (row['id'] as String): ((row['name'] as String?)?.trim() ?? ''),
        };
        final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
        for (final row
            in (rows as List<dynamic>).cast<Map<String, dynamic>>()) {
          final bookId = (row['book_id'] as String?) ?? '';
          final gradeLabel = (row['grade_label'] as String?)?.trim() ?? '';
          if (bookId.isEmpty || gradeLabel.isEmpty) continue;
          out.add({
            'book_id': bookId,
            'grade_label': gradeLabel,
            'order_index': _asInt(row['order_index']) ?? 0,
            'book_name': nameById[bookId] ?? '',
          });
        }
        return out;
      }
    } catch (e, st) {
      print('[RES][flowTextbookLinks] load failed: $e\n$st');
      return <Map<String, dynamic>>[];
    }
  }

  Future<void> saveFlowTextbookLinks(
    String flowId,
    List<Map<String, dynamic>> links,
  ) async {
    if (flowId.trim().isEmpty) return;
    final academyId = await TenantService.instance.getActiveAcademyId() ??
        await TenantService.instance.ensureActiveAcademy();
    final supa = Supabase.instance.client;

    await supa.from('flow_textbook_links').delete().match({
      'academy_id': academyId,
      'flow_id': flowId,
    });

    if (links.isEmpty) return;
    final Set<String> dedup = <String>{};
    final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[];
    for (final link in links) {
      final bookId = (link['book_id'] as String?)?.trim() ?? '';
      final gradeLabel = (link['grade_label'] as String?)?.trim() ?? '';
      if (bookId.isEmpty || gradeLabel.isEmpty) continue;
      final key = '$bookId|$gradeLabel';
      if (!dedup.add(key)) continue;
      rows.add({
        'academy_id': academyId,
        'flow_id': flowId,
        'book_id': bookId,
        'grade_label': gradeLabel,
        'order_index': rows.length,
      });
    }
    if (rows.isNotEmpty) {
      await supa.from('flow_textbook_links').insert(rows);
    }
  }

  Future<Map<String, dynamic>?> loadTextbookMetadataPayload({
    required String bookId,
    required String gradeLabel,
  }) async {
    if (bookId.trim().isEmpty || gradeLabel.trim().isEmpty) return null;
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final row = await supa
          .from('textbook_metadata')
          .select('page_offset,payload,textbook_type')
          .match({
        'academy_id': academyId,
        'book_id': bookId,
        'grade_label': gradeLabel,
      }).maybeSingle();
      if (row == null) return null;
      return Map<String, dynamic>.from(row);
    } catch (e, st) {
      print('[RES][textbookMetadataPayload] load failed: $e\n$st');
      return null;
    }
  }

  /// Loads the VLM-detected problem regions for [bookId] / [gradeLabel]
  /// from `textbook_problem_crops`. We project only the columns the
  /// student app needs (coordinates + identification), deliberately
  /// omitting `storage_key` / `file_size_bytes` because the new flow
  /// persists regions without crop images.
  ///
  /// Returns rows already sorted by (big_order, mid_order, sub_key,
  /// raw_page, problem_number). Callers typically re-group by page.
  Future<List<Map<String, dynamic>>> loadTextbookProblemRegions({
    required String bookId,
    String? gradeLabel,
  }) async {
    if (bookId.trim().isEmpty) return <Map<String, dynamic>>[];
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      var query = supa
          .from('textbook_problem_crops')
          .select(
            'id, big_order, mid_order, sub_key, big_name, mid_name, '
            'raw_page, display_page, section, '
            'problem_number, label, is_set_header, set_from, set_to, '
            'content_group_kind, content_group_label, content_group_title, '
            'content_group_order, '
            'column_index, bbox_1k, item_region_1k',
          )
          .eq('academy_id', academyId)
          .eq('book_id', bookId);
      if (gradeLabel != null && gradeLabel.trim().isNotEmpty) {
        query = query.eq('grade_label', gradeLabel.trim());
      }
      final rows = await query
          .order('big_order')
          .order('mid_order')
          .order('sub_key')
          .order('raw_page')
          .order('problem_number');
      if (rows is! List) return <Map<String, dynamic>>[];
      final out = <Map<String, dynamic>>[];
      for (final row in rows) {
        if (row is Map) out.add(Map<String, dynamic>.from(row));
      }
      return out;
    } catch (e, st) {
      // ignore: avoid_print
      print('[RES][textbookProblemRegions] load failed: $e\n$st');
      return <Map<String, dynamic>>[];
    }
  }

  /// Loads textbook problem rows with their Stage-2 answer sidecar attached.
  ///
  /// The result keeps the crop row fields at top-level and adds nullable
  /// answer fields (`answer_kind`, `answer_text`, `answer_latex_2d`, ...).
  Future<List<Map<String, dynamic>>> loadTextbookProblemRegionsForGrading({
    required String bookId,
    String? gradeLabel,
    Iterable<String> cropIds = const <String>[],
    Iterable<int> displayPages = const <int>[],
  }) async {
    final safeBookId = bookId.trim();
    if (safeBookId.isEmpty) return <Map<String, dynamic>>[];
    final safeCropIds = cropIds
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final safeDisplayPages = displayPages
        .where((e) => e > 0)
        .toSet()
        .toList(growable: false)
      ..sort();
    if (safeCropIds.isEmpty && safeDisplayPages.isEmpty) {
      return <Map<String, dynamic>>[];
    }

    Iterable<List<T>> chunks<T>(List<T> values, int size) sync* {
      for (var i = 0; i < values.length; i += size) {
        final end = (i + size) > values.length ? values.length : i + size;
        yield values.sublist(i, end);
      }
    }

    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final byCropId = <String, Map<String, dynamic>>{};

      Future<void> collect({
        List<String> ids = const <String>[],
        List<int> pages = const <int>[],
      }) async {
        var query = supa
            .from('textbook_problem_crops')
            .select(
              'id, big_order, mid_order, sub_key, big_name, mid_name, '
              'raw_page, display_page, section, '
              'problem_number, label, is_set_header, set_from, set_to, '
              'content_group_kind, content_group_label, content_group_title, '
              'content_group_order, pb_question_uid',
            )
            .eq('academy_id', academyId)
            .eq('book_id', safeBookId);
        final safeGrade = (gradeLabel ?? '').trim();
        if (safeGrade.isNotEmpty) {
          query = query.eq('grade_label', safeGrade);
        }
        if (ids.isNotEmpty) {
          query = query.inFilter('id', ids);
        }
        if (pages.isNotEmpty) {
          query = query.inFilter('display_page', pages);
        }
        final rows = await query
            .order('big_order')
            .order('mid_order')
            .order('sub_key')
            .order('display_page')
            .order('problem_number');
        for (final row in rows) {
          final map = Map<String, dynamic>.from(row);
          final id = '${map['id'] ?? ''}'.trim();
          if (id.isEmpty) continue;
          byCropId[id] = map;
        }
      }

      for (final ids in chunks(safeCropIds, 250)) {
        await collect(ids: ids);
      }
      for (final pages in chunks(safeDisplayPages, 250)) {
        await collect(pages: pages);
      }

      if (byCropId.isEmpty) return <Map<String, dynamic>>[];
      try {
        for (final ids in chunks(byCropId.keys.toList(growable: false), 250)) {
          final answerRows = await supa
              .from('textbook_problem_answers')
              .select(
                'crop_id, answer_kind, answer_text, answer_latex_2d, '
                'answer_source, raw_page, display_page, bbox_1k, note, '
                'answer_image_bucket, answer_image_path, '
                'answer_image_width_px, answer_image_height_px, '
                'answer_image_size_bytes, answer_image_content_hash',
              )
              .inFilter('crop_id', ids);
          for (final raw in answerRows) {
            final answer = Map<String, dynamic>.from(raw);
            final cropId = '${answer['crop_id'] ?? ''}'.trim();
            final crop = byCropId[cropId];
            if (crop == null) continue;
            final imageBucket = '${answer['answer_image_bucket'] ?? ''}'.trim();
            final imagePath = '${answer['answer_image_path'] ?? ''}'.trim();
            var imageUrl = '';
            if (imageBucket.isNotEmpty && imagePath.isNotEmpty) {
              try {
                imageUrl = await supa.storage
                    .from(imageBucket)
                    .createSignedUrl(imagePath, 60 * 30);
              } catch (_) {
                imageUrl = '';
              }
            }
            crop.addAll({
              'answer_kind': answer['answer_kind'],
              'answer_text': answer['answer_text'],
              'answer_latex_2d': answer['answer_latex_2d'],
              'answer_source': answer['answer_source'],
              'answer_raw_page': answer['raw_page'],
              'answer_display_page': answer['display_page'],
              'answer_bbox_1k': answer['bbox_1k'],
              'answer_note': answer['note'],
              'answer_image_bucket': answer['answer_image_bucket'],
              'answer_image_path': answer['answer_image_path'],
              'answer_image_url': imageUrl,
              'answer_image_width_px': answer['answer_image_width_px'],
              'answer_image_height_px': answer['answer_image_height_px'],
              'answer_image_size_bytes': answer['answer_image_size_bytes'],
              'answer_image_content_hash': answer['answer_image_content_hash'],
            });
          }
        }
      } catch (_) {
        // Stage-2 answer sidecar can be absent while crop metadata is present.
      }

      final out = byCropId.values.toList(growable: false);
      out.sort((a, b) {
        final byBig = (_asInt(a['big_order']) ?? -1)
            .compareTo(_asInt(b['big_order']) ?? -1);
        if (byBig != 0) return byBig;
        final byMid = (_asInt(a['mid_order']) ?? -1)
            .compareTo(_asInt(b['mid_order']) ?? -1);
        if (byMid != 0) return byMid;
        final bySub =
            '${a['sub_key'] ?? ''}'.compareTo('${b['sub_key'] ?? ''}');
        if (bySub != 0) return bySub;
        final byPage = (_asInt(a['display_page']) ?? _asInt(a['raw_page']) ?? 0)
            .compareTo(_asInt(b['display_page']) ?? _asInt(b['raw_page']) ?? 0);
        if (byPage != 0) return byPage;
        return '${a['problem_number'] ?? ''}'
            .compareTo('${b['problem_number'] ?? ''}');
      });
      return out;
    } catch (e, st) {
      // ignore: avoid_print
      print('[RES][textbookProblemRegionsForGrading] load failed: $e\n$st');
      return <Map<String, dynamic>>[];
    }
  }

  Future<List<Map<String, dynamic>>> loadHomeworkUnitStats({
    required String bookId,
    required String gradeLabel,
    String groupLevel = 'small',
    DateTime? from,
    DateTime? to,
  }) async {
    if (bookId.trim().isEmpty || gradeLabel.trim().isEmpty) {
      return <Map<String, dynamic>>[];
    }
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final params = <String, dynamic>{
        'p_academy_id': academyId,
        'p_book_id': bookId,
        'p_grade_label': gradeLabel,
        'p_group_level': groupLevel,
      };
      if (from != null) {
        params['p_from'] = from.toUtc().toIso8601String();
      }
      if (to != null) {
        params['p_to'] = to.toUtc().toIso8601String();
      }
      final rows = await supa.rpc('homework_unit_stats', params: params);
      if (rows is! List) return <Map<String, dynamic>>[];
      final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
      for (final row in rows) {
        if (row is Map) {
          out.add(Map<String, dynamic>.from(row));
        }
      }
      return out;
    } catch (e, st) {
      print('[RES][homeworkUnitStats] load failed: $e\n$st');
      return <Map<String, dynamic>>[];
    }
  }

  Future<void> deleteResourceFile(String fileId) async {
    await AcademyDbService.instance.deleteResourceFileLinksByFileId(fileId);
    await AcademyDbService.instance.deleteResourceFileOrdersByFileId(fileId);
    await AcademyDbService.instance.deleteResourceFile(fileId);
    if (TagPresetService.dualWrite) {
      try {
        final supa = Supabase.instance.client;
        final academyId = await TenantService.instance.getActiveAcademyId() ??
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
        final academyId = await TenantService.instance.getActiveAcademyId() ??
            await TenantService.instance.ensureActiveAcademy();
        final userId = Supabase.instance.client.auth.currentUser?.id;
        if (userId != null) {
          final data = await Supabase.instance.client
              .from('resource_favorites')
              .select('file_id')
              .match({'academy_id': academyId, 'user_id': userId});
          final set =
              (data as List).map((r) => (r['file_id'] as String)).toSet();
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
        final academyId = await TenantService.instance.getActiveAcademyId() ??
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
    await dbClient.delete('resource_favorites',
        where: 'file_id = ?', whereArgs: [fileId]);
    if (TagPresetService.dualWrite) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ??
            await TenantService.instance.ensureActiveAcademy();
        final userId = Supabase.instance.client.auth.currentUser?.id;
        if (userId != null) {
          await Supabase.instance.client
              .from('resource_favorites')
              .delete()
              .match({
            'academy_id': academyId,
            'file_id': fileId,
            'user_id': userId,
          });
        }
      } catch (_) {}
    }
  }

  // ======== RESOURCE FILE BOOKMARKS ========
  Future<List<Map<String, dynamic>>> loadResourceFileBookmarks(
      String fileId) async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ??
            await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        final data = await supa
            .from('resource_file_bookmarks')
            .select('name,description,path,order_index')
            .match({'academy_id': academyId, 'file_id': fileId}).order(
                'order_index');
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
      await txn.delete('resource_file_bookmarks',
          where: 'file_id = ?', whereArgs: [fileId]);
      for (int i = 0; i < items.length; i++) {
        final it = Map<String, dynamic>.from(items[i]);
        it['file_id'] = fileId;
        it['order_index'] = i;
        await txn.insert('resource_file_bookmarks', it);
      }
    });
    if (TagPresetService.dualWrite) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ??
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
