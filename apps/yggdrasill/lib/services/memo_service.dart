import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/memo.dart';
import 'academy_db.dart';
import 'runtime_flags.dart';
import 'tag_preset_service.dart';
import 'tenant_service.dart';

class MemoService {
  MemoService._internal();
  static final MemoService instance = MemoService._internal();

  static const String _selectFull =
      'id,original,summary,category,scheduled_at,dismissed,created_at,updated_at,recurrence_type,weekdays,recurrence_end,recurrence_count,inquiry_phone,inquiry_school_grade,inquiry_availability,inquiry_note,inquiry_sort_index';

  static const String _selectNoInquiry =
      'id,original,summary,category,scheduled_at,dismissed,created_at,updated_at,recurrence_type,weekdays,recurrence_end,recurrence_count';

  static const String _selectLegacy =
      'id,original,summary,scheduled_at,dismissed,created_at,updated_at,recurrence_type,weekdays,recurrence_end,recurrence_count';

  final ValueNotifier<List<Memo>> memosNotifier = ValueNotifier<List<Memo>>([]);
  List<Memo> _memos = [];

  List<Memo> get memos => List.unmodifiable(_memos);

  static Memo _memoFromSupabaseMap(Map<String, dynamic> m) {
    final String? schedStr = m['scheduled_at'] as String?;
    final String? createdStr = m['created_at'] as String?;
    final String? updatedStr = m['updated_at'] as String?;
    final String? weekdaysStr = m['weekdays'] as String?;
    final String? recurEndStr = m['recurrence_end'] as String?;
    final String? category = m['category'] as String?;
    final dynamic sortIdx = m['inquiry_sort_index'];
    return Memo(
      id: m['id'] as String,
      original: (m['original'] as String?) ?? '',
      summary: (m['summary'] as String?) ?? '',
      categoryKey: MemoCategory.normalize(category),
      scheduledAt: (schedStr != null && schedStr.isNotEmpty) ? DateTime.parse(schedStr) : null,
      dismissed: (m['dismissed'] as bool?) ?? false,
      createdAt: (createdStr != null && createdStr.isNotEmpty)
          ? DateTime.parse(createdStr)
          : DateTime.now(),
      updatedAt: (updatedStr != null && updatedStr.isNotEmpty)
          ? DateTime.parse(updatedStr)
          : DateTime.now(),
      recurrenceType: m['recurrence_type'] as String?,
      weekdays: (weekdaysStr == null || weekdaysStr.isEmpty)
          ? null
          : weekdaysStr.split(',').where((e) => e.isNotEmpty).map(int.parse).toList(),
      recurrenceEnd:
          (recurEndStr != null && recurEndStr.isNotEmpty) ? DateTime.parse(recurEndStr) : null,
      recurrenceCount: m['recurrence_count'] as int?,
      inquiryPhone: m['inquiry_phone'] as String?,
      inquirySchoolGrade: m['inquiry_school_grade'] as String?,
      inquiryAvailability: m['inquiry_availability'] as String?,
      inquiryNote: m['inquiry_note'] as String?,
      inquirySortIndex: sortIdx is int
          ? sortIdx
          : (sortIdx is num)
              ? sortIdx.toInt()
              : null,
    );
  }

  Map<String, dynamic> _rowForSupabase(Memo memo, String academyId) {
    return {
      'id': memo.id,
      'academy_id': academyId,
      'original': memo.original,
      'summary': memo.summary,
      'category': memo.categoryKey,
      'scheduled_at': memo.scheduledAt?.toIso8601String(),
      'dismissed': memo.dismissed,
      'recurrence_type': memo.recurrenceType,
      'weekdays': memo.weekdays?.join(','),
      'recurrence_end': memo.recurrenceEnd != null
          ? memo.recurrenceEnd!.toIso8601String().substring(0, 10)
          : null,
      'recurrence_count': memo.recurrenceCount,
      'inquiry_phone': memo.inquiryPhone,
      'inquiry_school_grade': memo.inquirySchoolGrade,
      'inquiry_availability': memo.inquiryAvailability,
      'inquiry_note': memo.inquiryNote,
      'inquiry_sort_index': memo.inquirySortIndex,
    }..removeWhere((k, v) => v == null);
  }

  Future<void> _supabaseUpsert(Memo memo) async {
    final academyId = await TenantService.instance.getActiveAcademyId() ??
        await TenantService.instance.ensureActiveAcademy();
    final supa = Supabase.instance.client;
    var row = _rowForSupabase(memo, academyId);
    try {
      await supa.from('memos').upsert(row, onConflict: 'id');
      return;
    } catch (e) {
      if (kDebugMode && memoIsFormInquiryForList(memo)) {
        debugPrint(
          '[MemoService] memos upsert failed; retrying without inquiry_* columns. '
          'Apply supabase/migrations for inquiry fields or rows lose structured fields on reload. error=$e',
        );
      }
    }
    final noInquiry = Map<String, dynamic>.from(row)
      ..remove('inquiry_phone')
      ..remove('inquiry_school_grade')
      ..remove('inquiry_availability')
      ..remove('inquiry_note')
      ..remove('inquiry_sort_index');
    try {
      await supa.from('memos').upsert(noInquiry, onConflict: 'id');
      return;
    } catch (_) {}
    final noCat = Map<String, dynamic>.from(noInquiry)..remove('category');
    await supa.from('memos').upsert(noCat, onConflict: 'id');
  }

  Future<void> loadMemos() async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ??
            await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        dynamic rows;
        try {
          rows = await supa
              .from('memos')
              .select(_selectFull)
              .eq('academy_id', academyId)
              .order('scheduled_at', ascending: true);
        } catch (_) {
          try {
            rows = await supa
                .from('memos')
                .select(_selectNoInquiry)
                .eq('academy_id', academyId)
                .order('scheduled_at', ascending: true);
          } catch (_) {
            rows = await supa
                .from('memos')
                .select(_selectLegacy)
                .eq('academy_id', academyId)
                .order('scheduled_at', ascending: true);
          }
        }
        final List<dynamic> list = rows as List<dynamic>;
        _memos = list.map<Memo>((e) => _memoFromSupabaseMap(e as Map<String, dynamic>)).toList();
        memosNotifier.value = List.unmodifiable(_memos);
        return;
      } catch (e, st) {
        print('[SUPA][memos load] $e\n$st');
      }
    }
    if (RuntimeFlags.serverOnly) {
      _memos = [];
      memosNotifier.value = List.unmodifiable(_memos);
      return;
    }
    final rows = await AcademyDbService.instance.getMemos();
    _memos = rows.map((m) => Memo.fromMap(m)).toList();
    memosNotifier.value = List.unmodifiable(_memos);
  }

  /// 새 문의 메모 append 시 부여할 sort index (기존 inquiry 중 max+1).
  int nextInquirySortIndexForAppend() {
    var max = -1;
    for (final m in _memos) {
      if (!memoIsFormInquiryForList(m)) continue;
      final s = m.inquirySortIndex;
      if (s != null && s > max) max = s;
    }
    return max + 1;
  }

  Future<void> reorderInquiryMemos(List<String> idsInOrder) async {
    if (idsInOrder.isEmpty) return;
    final now = DateTime.now();
    final next = List<Memo>.from(_memos);
    for (var i = 0; i < idsInOrder.length; i++) {
      final id = idsInOrder[i];
      final idx = next.indexWhere((m) => m.id == id);
      if (idx == -1) continue;
      final m = next[idx];
      if (!memoIsFormInquiryForList(m)) continue;
      next[idx] = m.copyWith(inquirySortIndex: i, updatedAt: now);
    }
    _memos = next;
    memosNotifier.value = List.unmodifiable(_memos);

    for (final id in idsInOrder) {
      final idx = _memos.indexWhere((m) => m.id == id);
      if (idx == -1) continue;
      final m = _memos[idx];
      if (!memoIsFormInquiryForList(m)) continue;
      await updateMemo(m);
    }
  }

  Future<void> addMemo(Memo memo) async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        await _supabaseUpsert(memo);
        _memos.insert(0, memo);
        memosNotifier.value = List.unmodifiable(_memos);
        return;
      } catch (e, st) {
        print('[SUPA][memos add] $e\n$st');
      }
    }
    _memos.insert(0, memo);
    memosNotifier.value = List.unmodifiable(_memos);
    if (!RuntimeFlags.serverOnly) {
      await AcademyDbService.instance.addMemo(memo.toMap());
    }
  }

  Future<void> updateMemo(Memo memo) async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        await _supabaseUpsert(memo);
        final idx = _memos.indexWhere((m) => m.id == memo.id);
        if (idx != -1) _memos[idx] = memo;
        memosNotifier.value = List.unmodifiable(_memos);
        return;
      } catch (e, st) {
        print('[SUPA][memos update] $e\n$st');
      }
    }
    final idx = _memos.indexWhere((m) => m.id == memo.id);
    if (idx != -1) {
      _memos[idx] = memo;
      memosNotifier.value = List.unmodifiable(_memos);
      if (!RuntimeFlags.serverOnly) {
        await AcademyDbService.instance.updateMemo(memo.id, memo.toMap());
      }
    }
  }

  Future<void> deleteMemo(String id) async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        await Supabase.instance.client.from('memos').delete().eq('id', id);
        _memos.removeWhere((m) => m.id == id);
        memosNotifier.value = List.unmodifiable(_memos);
        return;
      } catch (e, st) {
        print('[SUPA][memos delete] $e\n$st');
      }
    }
    _memos.removeWhere((m) => m.id == id);
    memosNotifier.value = List.unmodifiable(_memos);
    if (!RuntimeFlags.serverOnly) {
      await AcademyDbService.instance.deleteMemo(id);
    }
  }
}
