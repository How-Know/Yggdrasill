import 'package:supabase_flutter/supabase_flutter.dart';

import 'academy_db.dart';
import 'runtime_flags.dart';
import 'tag_preset_service.dart';
import 'tenant_service.dart';

class AnswerKeyService {
  AnswerKeyService._internal();
  static final AnswerKeyService instance = AnswerKeyService._internal();

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

    // 서버 백필(초기 1회): 서버가 비어있고 로컬에 데이터가 있으면 업로드
    if (TagPresetService.dualWrite && TagPresetService.preferSupabaseRead) {
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
    await AcademyDbService.instance.saveAnswerKeyBook(row);
    if (TagPresetService.dualWrite) {
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
      }
    }
  }

  Future<void> saveAnswerKeyBooks(List<Map<String, dynamic>> rows) async {
    await AcademyDbService.instance.saveAnswerKeyBooks(rows);
    if (TagPresetService.dualWrite) {
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
      } catch (e, st) {
        // ignore: avoid_print
        print('[AnswerKey][books saveAll] supabase write failed: $e\n$st');
      }
    }
  }

  Future<void> deleteAnswerKeyBook(String id) async {
    await AcademyDbService.instance.deleteAnswerKeyBook(id);
    if (TagPresetService.dualWrite) {
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

    // 서버 백필(초기 1회)
    if (TagPresetService.dualWrite && TagPresetService.preferSupabaseRead) {
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
    await AcademyDbService.instance.saveAnswerKeyBookPdf(row);
    if (TagPresetService.dualWrite) {
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
      }
    }
  }

  Future<void> deleteAnswerKeyBookPdf({
    required String bookId,
    required String gradeKey,
  }) async {
    await AcademyDbService.instance.deleteAnswerKeyBookPdf(bookId: bookId, gradeKey: gradeKey);
    if (TagPresetService.dualWrite) {
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


