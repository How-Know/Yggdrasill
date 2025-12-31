import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart';

import 'academy_db.dart';
import 'runtime_flags.dart';
import 'tag_preset_service.dart';
import 'tenant_service.dart';

class AnswerKeyService {
  AnswerKeyService._internal();
  static final AnswerKeyService instance = AnswerKeyService._internal();

  bool get _writeServer => TagPresetService.preferSupabaseRead || TagPresetService.dualWrite;
  bool get _writeLocal =>
      !RuntimeFlags.serverOnly && (!TagPresetService.preferSupabaseRead || TagPresetService.dualWrite);
  bool get _strictServer => RuntimeFlags.serverOnly || TagPresetService.preferSupabaseRead;

  // ======== GRADES (custom course names) ========
  Future<List<Map<String, dynamic>>> loadAnswerKeyGrades() async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId =
            await TenantService.instance.getActiveAcademyId() ??
                await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        final data = await supa
            .from('answer_key_grades')
            .select('grade_key,label,order_index')
            .eq('academy_id', academyId)
            .order('order_index');
        final list = (data as List).cast<Map<String, dynamic>>();
        if (list.isNotEmpty) return list;
      } catch (e, st) {
        // ignore: avoid_print
        print('[AnswerKey][grades] server load failed: $e\n$st');
        if (RuntimeFlags.serverOnly) {
          return <Map<String, dynamic>>[];
        }
      }
    }

    if (RuntimeFlags.serverOnly) {
      return <Map<String, dynamic>>[];
    }
    final local = await AcademyDbService.instance.loadAnswerKeyGrades();

    // 서버 백필(초기 1회): 서버 우선 모드에서 서버가 비어있고 로컬에 데이터가 있으면 업로드
    if (!RuntimeFlags.serverOnly && TagPresetService.preferSupabaseRead) {
      try {
        final academyId =
            await TenantService.instance.getActiveAcademyId() ??
                await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        final exists = await supa
            .from('answer_key_grades')
            .select('grade_key')
            .eq('academy_id', academyId)
            .limit(1);
        if ((exists as List).isEmpty && local.isNotEmpty) {
          // ignore: avoid_print
          print('[AnswerKey][grades] backfill local->supabase count=' +
              local.length.toString());
          await saveAnswerKeyGrades(local);
        }
      } catch (_) {}
    }

    return local;
  }

  Future<void> saveAnswerKeyGrades(List<Map<String, dynamic>> rows) async {
    if (_writeLocal) {
      await AcademyDbService.instance.saveAnswerKeyGrades(rows);
    }
    if (_writeServer) {
      try {
        final academyId =
            await TenantService.instance.getActiveAcademyId() ??
                await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        // 전체 삭제 후 현재 상태를 그대로 저장(삭제 반영)
        await supa.from('answer_key_grades').delete().eq('academy_id', academyId);
        if (rows.isNotEmpty) {
          final up = rows.map((r) {
            return {
              'academy_id': academyId,
              'grade_key': r['grade_key'],
              'label': r['label'],
              'order_index': r['order_index'],
            };
          }).toList();
          await supa.from('answer_key_grades').insert(up);
        }
        // ✅ 진단/검증: 저장 직후 서버에 실제 반영됐는지 확인(과정 편집은 빈번하지 않아서 부담이 작음)
        try {
          final data = await supa
              .from('answer_key_grades')
              .select('grade_key')
              .eq('academy_id', academyId);
          final serverCount = (data as List).length;
          if (kDebugMode) {
            // ignore: avoid_print
            print('[AnswerKey][grades save][verify] academy=$academyId serverCount=$serverCount expected=${rows.length}'
                ' flags(preferSupabaseRead=' +
                TagPresetService.preferSupabaseRead.toString() +
                ', dualWrite=' +
                TagPresetService.dualWrite.toString() +
                ', serverOnly=' +
                RuntimeFlags.serverOnly.toString() +
                ')');
          }
          // 서버 우선/서버 전용 모드에서는 반드시 서버 반영을 보장(미반영이면 실패로 처리)
          if (_strictServer && serverCount != rows.length) {
            throw StateError('answer_key_grades verify failed: serverCount=$serverCount expected=${rows.length}');
          }
        } catch (e, st) {
          if (kDebugMode) {
            // ignore: avoid_print
            print('[AnswerKey][grades save][verify] failed: $e\n$st');
          }
          if (_strictServer) rethrow;
        }
      } catch (e, st) {
        // ignore: avoid_print
        print('[AnswerKey][grades save] supabase write failed: $e\n$st');
        if (_strictServer) rethrow;
      }
    }
  }

  // ======== BOOKS ========
  Future<List<Map<String, dynamic>>> loadAnswerKeyBooks() async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId =
            await TenantService.instance.getActiveAcademyId() ??
                await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        final data = await supa
            .from('answer_key_books')
            .select('id,name,description,grade_key,order_index')
            .eq('academy_id', academyId)
            .order('order_index');
        final list = (data as List).cast<Map<String, dynamic>>();
        if (list.isNotEmpty) return list;
      } catch (e, st) {
        // ignore: avoid_print
        print('[AnswerKey][books] server load failed: $e\n$st');
        if (RuntimeFlags.serverOnly) {
          return <Map<String, dynamic>>[];
        }
      }
    }

    // fallback to local
    if (RuntimeFlags.serverOnly) {
      return <Map<String, dynamic>>[];
    }
    final local = await AcademyDbService.instance.loadAnswerKeyBooks();

    // 서버 백필(초기 1회): 서버 우선 모드에서 서버가 비어있고 로컬에 데이터가 있으면 업로드
    if (!RuntimeFlags.serverOnly && TagPresetService.preferSupabaseRead) {
      try {
        final academyId =
            await TenantService.instance.getActiveAcademyId() ??
                await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        final exists = await supa
            .from('answer_key_books')
            .select('id')
            .eq('academy_id', academyId)
            .limit(1);
        if ((exists as List).isEmpty && local.isNotEmpty) {
          // ignore: avoid_print
          print('[AnswerKey][books] backfill local->supabase count=' +
              local.length.toString());
          await saveAnswerKeyBooks(local);
        }
      } catch (_) {}
    }

    return local;
  }

  Future<void> saveAnswerKeyBook(Map<String, dynamic> row) async {
    if (_writeLocal) {
      await AcademyDbService.instance.saveAnswerKeyBook(row);
    }
    if (_writeServer) {
      try {
        final academyId =
            await TenantService.instance.getActiveAcademyId() ??
                await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        final up = {
          'id': row['id'],
          'academy_id': academyId,
          'name': row['name'],
          'description': row['description'],
          'grade_key': row['grade_key'],
          'order_index': row['order_index'],
        };
        await supa.from('answer_key_books').upsert(up, onConflict: 'id');
      } catch (e, st) {
        // ignore: avoid_print
        print('[AnswerKey][books save] supabase upsert failed: $e\n$st');
        if (_strictServer) rethrow;
      }
    }
  }

  Future<void> saveAnswerKeyBooks(List<Map<String, dynamic>> rows) async {
    if (_writeLocal) {
      await AcademyDbService.instance.saveAnswerKeyBooks(rows);
    }
    if (_writeServer) {
      try {
        final academyId =
            await TenantService.instance.getActiveAcademyId() ??
                await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        // NOTE: 책 테이블을 전체 삭제하면(academy_id 조건) child 테이블(PDF 링크)이 FK cascade로 함께 삭제될 수 있음.
        // 그래서 "upsert-only"로 동작시킨다. (현재 UI는 삭제 기능이 없으므로, 누적/정리는 추후 필요 시 별도 구현)
        if (rows.isNotEmpty) {
          final up = rows
              .map((r) => {
                    'id': r['id'],
                    'academy_id': academyId,
                    'name': r['name'],
                    'description': r['description'],
                    'grade_key': r['grade_key'],
                    'order_index': r['order_index'],
                  })
              .toList();
          await supa.from('answer_key_books').upsert(up, onConflict: 'id');
        }
        // ✅ 진단/검증(디버그): 저장 직후 서버 order_index가 기대값대로 반영됐는지 확인
        if (kDebugMode && rows.isNotEmpty) {
          try {
            final expected = <String, int>{
              for (final r in rows)
                if ((r['id'] as String?) != null)
                  (r['id'] as String): (r['order_index'] as int?) ?? 0,
            };
            final ids = expected.keys.toList();
            final data = await supa
                .from('answer_key_books')
                .select('id,order_index')
                .eq('academy_id', academyId)
                .inFilter('id', ids);
            final list = (data as List).cast<Map<String, dynamic>>();
            int mismatch = 0;
            for (final r in list) {
              final id = (r['id'] as String?) ?? '';
              final oi = (r['order_index'] as int?) ?? 0;
              final exp = expected[id];
              if (exp == null) continue;
              if (oi != exp) mismatch++;
            }
            // ignore: avoid_print
            print('[AnswerKey][books saveAll][verify] academy=$academyId mismatch=$mismatch count=${rows.length}'
                ' flags(preferSupabaseRead=' +
                TagPresetService.preferSupabaseRead.toString() +
                ', dualWrite=' +
                TagPresetService.dualWrite.toString() +
                ', serverOnly=' +
                RuntimeFlags.serverOnly.toString() +
                ')');
          } catch (e, st) {
            // ignore: avoid_print
            print('[AnswerKey][books saveAll][verify] failed: $e\n$st');
          }
        }
      } catch (e, st) {
        // ignore: avoid_print
        print('[AnswerKey][books saveAll] supabase write failed: $e\n$st');
        if (_strictServer) rethrow;
      }
    }
  }

  Future<void> deleteAnswerKeyBook(String id) async {
    if (_writeLocal) {
      await AcademyDbService.instance.deleteAnswerKeyBook(id);
    }
    if (_writeServer) {
      try {
        final academyId =
            await TenantService.instance.getActiveAcademyId() ??
                await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        await supa
            .from('answer_key_books')
            .delete()
            .match({'academy_id': academyId, 'id': id});
      } catch (_) {}
    }
  }

  // ======== BOOK PDF LINKS (per grade) ========
  Future<List<Map<String, dynamic>>> loadAnswerKeyBookPdfs() async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId =
            await TenantService.instance.getActiveAcademyId() ??
                await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        final data = await supa
            .from('answer_key_book_pdfs')
            .select('book_id,grade_key,path,name')
            .eq('academy_id', academyId);
        final list = (data as List).cast<Map<String, dynamic>>();
        if (list.isNotEmpty) return list;
      } catch (e, st) {
        // ignore: avoid_print
        print('[AnswerKey][pdfs] server load failed: $e\n$st');
        if (RuntimeFlags.serverOnly) {
          return <Map<String, dynamic>>[];
        }
      }
    }

    if (RuntimeFlags.serverOnly) {
      return <Map<String, dynamic>>[];
    }
    final local = await AcademyDbService.instance.loadAnswerKeyBookPdfs();

    // 서버 백필(초기 1회): 서버 우선 모드에서 서버가 비어있고 로컬에 데이터가 있으면 업로드
    if (!RuntimeFlags.serverOnly && TagPresetService.preferSupabaseRead) {
      try {
        final academyId =
            await TenantService.instance.getActiveAcademyId() ??
                await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        final exists = await supa
            .from('answer_key_book_pdfs')
            .select('book_id')
            .eq('academy_id', academyId)
            .limit(1);
        if ((exists as List).isEmpty && local.isNotEmpty) {
          // ignore: avoid_print
          print('[AnswerKey][pdfs] backfill local->supabase count=' +
              local.length.toString());
          for (final r in local) {
            await saveAnswerKeyBookPdf(r);
          }
        }
      } catch (_) {}
    }

    return local;
  }

  Future<void> saveAnswerKeyBookPdf(Map<String, dynamic> row) async {
    if (_writeLocal) {
      await AcademyDbService.instance.saveAnswerKeyBookPdf(row);
    }
    if (_writeServer) {
      try {
        final academyId =
            await TenantService.instance.getActiveAcademyId() ??
                await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        final up = {
          'academy_id': academyId,
          'book_id': row['book_id'],
          'grade_key': row['grade_key'],
          'path': row['path'],
          'name': row['name'],
        };
        await supa
            .from('answer_key_book_pdfs')
            .upsert(up, onConflict: 'academy_id,book_id,grade_key');
      } catch (e, st) {
        // ignore: avoid_print
        print('[AnswerKey][pdf save] supabase upsert failed: $e\n$st');
        if (_strictServer) rethrow;
      }
    }
  }

  Future<void> deleteAnswerKeyBookPdf({
    required String bookId,
    required String gradeKey,
  }) async {
    if (_writeLocal) {
      await AcademyDbService.instance.deleteAnswerKeyBookPdf(bookId: bookId, gradeKey: gradeKey);
    }
    if (_writeServer) {
      try {
        final academyId =
            await TenantService.instance.getActiveAcademyId() ??
                await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        await supa.from('answer_key_book_pdfs').delete().match({
          'academy_id': academyId,
          'book_id': bookId,
          'grade_key': gradeKey,
        });
      } catch (_) {}
    }
  }
}


