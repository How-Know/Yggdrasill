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

  final ValueNotifier<List<Memo>> memosNotifier = ValueNotifier<List<Memo>>([]);
  List<Memo> _memos = [];

  List<Memo> get memos => List.unmodifiable(_memos);

  Future<void> loadMemos() async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ??
            await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        final rows = await supa
            .from('memos')
            .select(
              'id,original,summary,scheduled_at,dismissed,created_at,updated_at,recurrence_type,weekdays,recurrence_end,recurrence_count',
            )
            .eq('academy_id', academyId)
            .order('scheduled_at', ascending: true);
        final List<dynamic> list = rows as List<dynamic>;
        _memos = list.map<Memo>((m) {
          final String? schedStr = m['scheduled_at'] as String?;
          final String? createdStr = m['created_at'] as String?;
          final String? updatedStr = m['updated_at'] as String?;
          final String? weekdaysStr = m['weekdays'] as String?;
          final String? recurEndStr = m['recurrence_end'] as String?;
          return Memo(
            id: m['id'] as String,
            original: (m['original'] as String?) ?? '',
            summary: (m['summary'] as String?) ?? '',
            scheduledAt:
                (schedStr != null && schedStr.isNotEmpty) ? DateTime.parse(schedStr) : null,
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
          );
        }).toList();
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

  Future<void> addMemo(Memo memo) async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ??
            await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        final row = {
          'id': memo.id,
          'academy_id': academyId,
          'original': memo.original,
          'summary': memo.summary,
          'scheduled_at': memo.scheduledAt?.toIso8601String(),
          'dismissed': memo.dismissed,
          'recurrence_type': memo.recurrenceType,
          'weekdays': memo.weekdays?.join(','),
          'recurrence_end': memo.recurrenceEnd?.toIso8601String().substring(0, 10),
          'recurrence_count': memo.recurrenceCount,
        }..removeWhere((k, v) => v == null);
        await supa.from('memos').upsert(row, onConflict: 'id');
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
        final academyId = await TenantService.instance.getActiveAcademyId() ??
            await TenantService.instance.ensureActiveAcademy();
        final supa = Supabase.instance.client;
        final row = {
          'id': memo.id,
          'academy_id': academyId,
          'original': memo.original,
          'summary': memo.summary,
          'scheduled_at': memo.scheduledAt?.toIso8601String(),
          'dismissed': memo.dismissed,
          'recurrence_type': memo.recurrenceType,
          'weekdays': memo.weekdays?.join(','),
          'recurrence_end': memo.recurrenceEnd?.toIso8601String().substring(0, 10),
          'recurrence_count': memo.recurrenceCount,
        }..removeWhere((k, v) => v == null);
        await supa.from('memos').upsert(row, onConflict: 'id');
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
















