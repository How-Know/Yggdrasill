import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/consult_note.dart';

class ConsultNoteService {
  ConsultNoteService._internal();
  static final ConsultNoteService instance = ConsultNoteService._internal();

  static const String _dirName = 'consult_notes';
  static const String _indexFileName = 'index.json';

  Future<Directory> _resolveNotesDir() async {
    // 1) Windows는 환경에 따라 Documents가 OneDrive로 매핑되기도 하고, 아니면 로컬 문서일 수도 있음.
    //    MSIX/설치형에서도 쓰기 가능한 경로를 보장하기 위해 documentsDirectory를 기본으로 사용.
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, _dirName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _indexFile() async {
    final dir = await _resolveNotesDir();
    return File(p.join(dir.path, _indexFileName));
  }

  Future<File> _noteFile(String id) async {
    final dir = await _resolveNotesDir();
    return File(p.join(dir.path, '$id.json'));
  }

  Future<List<ConsultNoteMeta>> listMetas() async {
    try {
      final idx = await _indexFile();
      if (await idx.exists()) {
        final map = jsonDecode(await idx.readAsString()) as Map<String, dynamic>;
        final list = (map['notes'] as List<dynamic>? ?? const <dynamic>[])
            .cast<Map<String, dynamic>>();
        final metas = list.map(ConsultNoteMeta.fromJson).toList();
        metas.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        return metas;
      }
    } catch (_) {}

    // index가 없거나 깨졌으면 폴더 스캔으로 복구(최소 메타만 추출)
    try {
      final dir = await _resolveNotesDir();
      final files = await dir
          .list()
          .where((e) => e is File)
          .cast<File>()
          .where((f) => f.path.toLowerCase().endsWith('.json'))
          .where((f) => p.basename(f.path).toLowerCase() != _indexFileName)
          .toList();
      final metas = <ConsultNoteMeta>[];
      for (final f in files) {
        try {
          final map = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
          final note = ConsultNote.fromJson(map);
          metas.add(ConsultNoteMeta(
            id: note.id,
            title: note.title,
            createdAt: note.createdAt,
            updatedAt: note.updatedAt,
            desiredWeekday: note.desiredWeekday,
            desiredHour: note.desiredHour,
            desiredMinute: note.desiredMinute,
            strokeCount: note.strokes.length,
          ));
        } catch (_) {}
      }
      metas.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      await _writeIndex(metas);
      return metas;
    } catch (_) {}

    return const <ConsultNoteMeta>[];
  }

  Future<ConsultNote?> load(String id) async {
    try {
      final file = await _noteFile(id);
      if (!await file.exists()) return null;
      final map = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return ConsultNote.fromJson(map);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(ConsultNote note) async {
    final file = await _noteFile(note.id);
    final jsonStr = const JsonEncoder.withIndent('  ').convert(note.toJson());
    await file.writeAsString(jsonStr, flush: true);
    final metas = await listMetas();
    final idx = metas.indexWhere((m) => m.id == note.id);
    final meta = ConsultNoteMeta(
      id: note.id,
      title: note.title,
      createdAt: note.createdAt,
      updatedAt: note.updatedAt,
      desiredWeekday: note.desiredWeekday,
      desiredHour: note.desiredHour,
      desiredMinute: note.desiredMinute,
      strokeCount: note.strokes.length,
    );
    final next = [...metas];
    if (idx == -1) {
      next.insert(0, meta);
    } else {
      next[idx] = meta;
    }
    next.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    await _writeIndex(next);
  }

  Future<void> delete(String id) async {
    try {
      final file = await _noteFile(id);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
    try {
      final metas = await listMetas();
      final next = metas.where((m) => m.id != id).toList();
      await _writeIndex(next);
    } catch (_) {}
  }

  Future<void> _writeIndex(List<ConsultNoteMeta> metas) async {
    final idx = await _indexFile();
    final map = <String, dynamic>{
      'version': 1,
      'notes': metas.map((m) => m.toJson()).toList(),
    };
    await idx.writeAsString(const JsonEncoder.withIndent('  ').convert(map), flush: true);
  }
}



