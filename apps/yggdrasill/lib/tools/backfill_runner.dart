import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/tenant_service.dart';
import '../services/academy_db.dart';
import '../services/tag_preset_service.dart';
import '../models/group_info.dart';
import '../models/class_info.dart';
import '../models/payment_record.dart';

/// One-shot backfill runner.
/// - Reads from local SQLite
/// - Upserts into current Supabase project under active academy_id
/// - Never deletes on server
class BackfillRunner {
  BackfillRunner._();

  static Future<void> runAll() async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId()
          ?? await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final only = const String.fromEnvironment('BACKFILL_ONLY', defaultValue: '').toLowerCase().trim();

      debugPrint('[BACKFILL] Start (academy_id=$academyId)');

      // Selective backfill
      if (only.isNotEmpty) {
        if (only == 'student_time_blocks' || only == 'stb' || only == 'w5') {
          final serverStudentIds = await _fetchServerStudentIds(supa, academyId);
          await _backfillW5W6W7(supa, academyId, serverStudentIds);
          debugPrint('[BACKFILL] Done');
          return;
        }
      }

      await _backfillTagPresets(supa, academyId);
      await _backfillGroupsAndClasses(supa, academyId);
      await _backfillResources(supa, academyId);
      await _backfillExamTables(supa, academyId);
      await _backfillW2(supa, academyId);
      final validStudentIds = await _backfillW4(supa, academyId);
      await _backfillTagEvents(supa, academyId);
      await _backfillW5W6W7(supa, academyId, validStudentIds);
      await _backfillMisc(supa, academyId);

      debugPrint('[BACKFILL] Done');
    } catch (e, st) {
      debugPrint('[BACKFILL][ERROR] $e\n$st');
    }
  }

  static String _toUuid(String raw, String ns) {
    // 이미 UUID면 그대로
    try {
      final maybe = raw.trim();
      if (maybe.length == 36 && maybe.contains('-')) return maybe;
    } catch (_) {}
    // 네임스페이스 기반 UUID v5 안정 변환(입력 문자열 → 고정 UUID)
    final v5 = const Uuid().v5(Uuid.NAMESPACE_URL, '$ns::$raw');
    return v5;
  }

  static Future<void> _backfillTagPresets(SupabaseClient supa, String academyId) async {
    try {
      // preferSupabase=false 일 때 로컬에서 로드됨
      final presets = await TagPresetService.instance.loadPresets();
      if (presets.isEmpty) {
        debugPrint('[BACKFILL][tag_presets] local=0 (skip)');
        return;
      }
      final rows = presets.map((p) => {
            'id': p.id,
            'academy_id': academyId,
            'name': p.name,
            // Postgres integer is 32-bit signed; map ARGB to signed int32
            'color': p.color.value.toSigned(32),
            'icon_code': p.icon.codePoint,
            'order_index': p.orderIndex,
          }).toList();
      await supa.from('tag_presets').upsert(rows, onConflict: 'id');
      debugPrint('[BACKFILL][tag_presets] upserted=${rows.length}');
    } catch (e, st) {
      debugPrint('[BACKFILL][tag_presets][ERROR] $e\n$st');
    }
  }

  static Future<void> _backfillGroupsAndClasses(SupabaseClient supa, String academyId) async {
    try {
      final groups = await AcademyDbService.instance.getGroups();
      if (groups.isNotEmpty) {
        final rows = groups.map((GroupInfo g) => {
              'id': _toUuid(g.id, 'groups'),
              'academy_id': academyId,
              'name': g.name,
              'description': g.description,
              'capacity': g.capacity,
              'duration': g.duration,
              'color': (g.color?.value ?? 0).toSigned(32),
            }).toList();
        await supa.from('groups').upsert(rows, onConflict: 'id');
        debugPrint('[BACKFILL][groups] upserted=${rows.length}');
      } else {
        debugPrint('[BACKFILL][groups] local=0 (skip)');
      }
    } catch (e, st) {
      debugPrint('[BACKFILL][groups][ERROR] $e\n$st');
    }

    try {
      final classes = await AcademyDbService.instance.getClasses();
      if (classes.isNotEmpty) {
        final rows = classes.map((ClassInfo c) => {
              'id': _toUuid(c.id, 'classes'),
              'academy_id': academyId,
              'name': c.name,
              'description': c.description,
              'capacity': c.capacity,
              'color': (c.color?.value ?? 0).toSigned(32),
            }).toList();
        await supa.from('classes').upsert(rows, onConflict: 'id');
        debugPrint('[BACKFILL][classes] upserted=${rows.length}');
      } else {
        debugPrint('[BACKFILL][classes] local=0 (skip)');
      }
    } catch (e, st) {
      debugPrint('[BACKFILL][classes][ERROR] $e\n$st');
    }
  }

  static Future<void> _backfillResources(SupabaseClient supa, String academyId) async {
    try {
      final folders = await AcademyDbService.instance.loadResourceFolders();
      final Set<String> folderIdSet = <String>{};
      if (folders.isNotEmpty) {
        final rows = folders.map((f) {
          final id = _toUuid(f['id'].toString(), 'resource_folders');
          folderIdSet.add(id);
          final parentId = f['parent_id'] == null ? null : _toUuid(f['parent_id'].toString(), 'resource_folders');
          return {
            'id': id,
            'academy_id': academyId,
            'name': f['name'],
            'category': f['category'],
            'order_index': f['order_index'],
            'parent_id': parentId,
          };
        }).toList();
        await supa.from('resource_folders').upsert(rows, onConflict: 'id');
        debugPrint('[BACKFILL][resource_folders] upserted=${rows.length}');
      } else {
        debugPrint('[BACKFILL][resource_folders] local=0 (skip)');
      }

      // Files depend on folders; compute again to ensure visibility
      final files = await AcademyDbService.instance.loadResourceFiles();
      if (files.isNotEmpty) {
        final rows = files.map((f) {
          final folderIdRaw = f['parent_id'];
          String? folderId;
          if (folderIdRaw != null) {
            final derived = _toUuid(folderIdRaw.toString(), 'resource_folders');
            folderId = folderIdSet.contains(derived) ? derived : null;
          }
          return {
            'id': _toUuid(f['id'].toString(), 'resource_files'),
            'academy_id': academyId,
            'name': f['name'],
            'url': f['url'],
            'category': f['category'],
            'order_index': f['order_index'],
            'folder_id': folderId,
          };
        }).toList();
        await supa.from('resource_files').upsert(rows, onConflict: 'id');
        debugPrint('[BACKFILL][resource_files] upserted=${rows.length}');
      } else {
        debugPrint('[BACKFILL][resource_files] local=0 (skip)');
      }
    } catch (e, st) {
      debugPrint('[BACKFILL][resource_folders/files][ERROR] $e\n$st');
    }

    // removed: merged into previous block to keep folderIdSet in scope
  }

  static Future<void> _backfillExamTables(SupabaseClient supa, String academyId) async {
    try {
      final schedules = await AcademyDbService.instance.loadAllExamSchedules();
      if (schedules.isNotEmpty) {
        final rows = schedules.map((r) => {
              'academy_id': academyId,
              'school': r['school'],
              'level': r['level'],
              'grade': r['grade'],
              'date': r['date'],
              'names_json': r['names_json'],
            }).toList();
        await supa.from('exam_schedules').upsert(rows, onConflict: 'academy_id,school,level,grade,date');
        debugPrint('[BACKFILL][exam_schedules] upserted=${rows.length}');
      }
    } catch (e, st) {
      debugPrint('[BACKFILL][exam_schedules][ERROR] $e\n$st');
    }

    try {
      final ranges = await AcademyDbService.instance.loadAllExamRanges();
      if (ranges.isNotEmpty) {
        final rows = ranges.map((r) => {
              'academy_id': academyId,
              'school': r['school'],
              'level': r['level'],
              'grade': r['grade'],
              'date': r['date'],
              'range_text': r['range_text'],
            }).toList();
        await supa.from('exam_ranges').upsert(rows, onConflict: 'academy_id,school,level,grade,date');
        debugPrint('[BACKFILL][exam_ranges] upserted=${rows.length}');
      }
    } catch (e, st) {
      debugPrint('[BACKFILL][exam_ranges][ERROR] $e\n$st');
    }

    try {
      final days = await AcademyDbService.instance.loadAllExamDays();
      if (days.isNotEmpty) {
        final rows = days.map((r) => {
              'academy_id': academyId,
              'school': r['school'],
              'level': r['level'],
              'grade': r['grade'],
              'date': r['date'],
            }).toList();
        await supa.from('exam_days').upsert(rows, onConflict: 'academy_id,school,level,grade,date');
        debugPrint('[BACKFILL][exam_days] upserted=${rows.length}');
      }
    } catch (e, st) {
      debugPrint('[BACKFILL][exam_days][ERROR] $e\n$st');
    }
  }

  static Future<void> _backfillW2(SupabaseClient supa, String academyId) async {
    // academy_settings -----------------------------------------------------
    try {
      final local = await AcademyDbService.instance.getAcademySettings();
      if (local != null) {
        final row = <String, dynamic>{
          'academy_id': academyId,
          'name': local['name'],
          'slogan': local['slogan'],
          'default_capacity': local['default_capacity'],
          'lesson_duration': local['lesson_duration'],
          'payment_type': local['payment_type'],
          // 'logo': local['logo'], // bytea 전송 호환 이슈 시 제외 유지
          'session_cycle': local['session_cycle'],
          'openai_api_key': local['openai_api_key'],
        }..removeWhere((k, v) => v == null);
        await supa.from('academy_settings').upsert(row, onConflict: 'academy_id');
        debugPrint('[BACKFILL][academy_settings] upserted=1');
      } else {
        debugPrint('[BACKFILL][academy_settings] local=null (skip)');
      }
    } catch (e, st) {
      debugPrint('[BACKFILL][academy_settings][ERROR] $e\n$st');
    }

    // operating_hours -----------------------------------------------------
    try {
      final hours = await AcademyDbService.instance.getOperatingHours();
      if (hours.isNotEmpty) {
        final rows = hours.map((h) {
          final breaks = h.breakTimes
              .map((b) => {
                    'startHour': b.startHour,
                    'startMinute': b.startMinute,
                    'endHour': b.endHour,
                    'endMinute': b.endMinute,
                  })
              .toList();
        final id = _toUuid('d${h.dayOfWeek}_${h.startHour}:${h.startMinute}-${h.endHour}:${h.endMinute}_${jsonEncode(breaks)}', 'operating_hours');
          return {
            'id': id,
            'academy_id': academyId,
            'day_of_week': h.dayOfWeek,
            'start_time': '${h.startHour.toString().padLeft(2, '0')}:${h.startMinute.toString().padLeft(2, '0')}',
            'end_time': '${h.endHour.toString().padLeft(2, '0')}:${h.endMinute.toString().padLeft(2, '0')}',
            'break_times': jsonEncode(breaks),
          };
        }).toList();
        await supa.from('operating_hours').upsert(rows, onConflict: 'id');
        debugPrint('[BACKFILL][operating_hours] upserted=${rows.length}');
      } else {
        debugPrint('[BACKFILL][operating_hours] local=0 (skip)');
      }
    } catch (e, st) {
      debugPrint('[BACKFILL][operating_hours][ERROR] $e\n$st');
    }

    // teachers ------------------------------------------------------------
    try {
      final teachers = await AcademyDbService.instance.getTeachers();
      if (teachers.isNotEmpty) {
        final rows = teachers.map((t) {
          final name = (t['name'] ?? '').toString();
          final email = (t['email'] ?? '').toString();
          final contact = (t['contact'] ?? '').toString();
          final id = _toUuid('${name}|${email}|${contact}', 'teachers');
          return {
            'id': id,
            'academy_id': academyId,
            'name': name,
            'role': t['role'],
            'contact': contact,
            'email': email,
            'description': t['description'],
          }..removeWhere((k, v) => v == null);
        }).toList();
        await supa.from('teachers').upsert(rows, onConflict: 'id');
        debugPrint('[BACKFILL][teachers] upserted=${rows.length}');
      } else {
        debugPrint('[BACKFILL][teachers] local=0 (skip)');
      }
    } catch (e, st) {
      debugPrint('[BACKFILL][teachers][ERROR] $e\n$st');
    }

    // kakao_reservations --------------------------------------------------
    try {
      final db = await AcademyDbService.instance.db;
      final rowsLocal = await db.query('kakao_reservations');
      if (rowsLocal.isNotEmpty) {
        final rows = rowsLocal.map((r) {
          final id = _toUuid((r['id'] ?? '').toString(), 'kakao_reservations');
          String? dt(String? s) => (s == null || s.isEmpty) ? null : DateTime.tryParse(s)?.toIso8601String();
          return {
            'id': id,
            'academy_id': academyId,
            'created_at': dt(r['created_at'] as String?),
            'message': r['message'],
            'name': r['name'],
            'student_name': r['student_name'],
            'phone': r['phone'],
            'desired_datetime': dt(r['desired_datetime'] as String?),
            'is_read': (r['is_read'] is int) ? ((r['is_read'] as int) != 0) : r['is_read'],
            'kakao_user_id': r['kakao_user_id'],
            'kakao_nickname': r['kakao_nickname'],
            'status': r['status'],
          }..removeWhere((k, v) => v == null);
        }).toList();
        await supa.from('kakao_reservations').upsert(rows, onConflict: 'id');
        debugPrint('[BACKFILL][kakao_reservations] upserted=${rows.length}');
      } else {
        debugPrint('[BACKFILL][kakao_reservations] local=0 (skip)');
      }
    } catch (e, st) {
      debugPrint('[BACKFILL][kakao_reservations][ERROR] $e\n$st');
    }
  }

  static Future<Set<String>> _backfillW4(SupabaseClient supa, String academyId) async {
    final Set<String> validStudentIds = <String>{};
    // students --------------------------------------------------------------
    try {
      final students = await AcademyDbService.instance.getStudents();
      if (students.isNotEmpty) {
        final rows = students.map((s) => {
              'id': _toUuid(s.id, 'students'),
              'academy_id': academyId,
              'name': s.name,
              'school': s.school,
              'education_level': s.educationLevel.index,
              'grade': s.grade,
            }).toList();
        await supa.from('students').upsert(rows, onConflict: 'id');
        debugPrint('[BACKFILL][students] upserted=${rows.length}');
        for (final s in students) {
          validStudentIds.add(_toUuid(s.id, 'students'));
        }
      } else {
        debugPrint('[BACKFILL][students] local=0 (skip)');
      }
    } catch (e, st) {
      debugPrint('[BACKFILL][students][ERROR] $e\n$st');
    }

    // student_basic_info ---------------------------------------------------
    try {
      final db = await AcademyDbService.instance.db;
      final rowsLocal = await db.query('student_basic_info');
      if (rowsLocal.isNotEmpty) {
        final rows = rowsLocal.map((r) {
          final rawStudentId = (r['student_id'] ?? '').toString();
          final rawGroupId = r['group_id'];
          String? groupId;
          if (rawGroupId != null && rawGroupId.toString().trim().isNotEmpty) {
            groupId = _toUuid(rawGroupId.toString(), 'groups');
          }
          return {
            'student_id': _toUuid(rawStudentId, 'students'),
            'academy_id': academyId,
            'phone_number': r['phone_number'],
            'parent_phone_number': r['parent_phone_number'],
            'group_id': groupId,
            'memo': r['memo'],
          }..removeWhere((k, v) => v == null);
        }).toList();
        await supa.from('student_basic_info').upsert(rows, onConflict: 'student_id');
        debugPrint('[BACKFILL][student_basic_info] upserted=${rows.length}');
      } else {
        debugPrint('[BACKFILL][student_basic_info] local=0 (skip)');
      }
    } catch (e, st) {
      debugPrint('[BACKFILL][student_basic_info][ERROR] $e\n$st');
    }

    // student_payment_info -------------------------------------------------
    try {
      final db = await AcademyDbService.instance.db;
      final rowsLocal = await db.query('student_payment_info');
      if (rowsLocal.isNotEmpty) {
        DateTime? fromMs(dynamic v) {
          if (v == null) return null;
          if (v is int) return DateTime.fromMillisecondsSinceEpoch(v, isUtc: true);
          if (v is String) {
            final ms = int.tryParse(v);
            if (ms != null) return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
          }
          return null;
        }
        bool? intToBool(dynamic v) {
          if (v is int) return v != 0;
          if (v is bool) return v;
          return null;
        }
        final rows = rowsLocal.map((r) {
          final rawStudentId = (r['student_id'] ?? '').toString();
          return {
            'academy_id': academyId,
            'student_id': _toUuid(rawStudentId, 'students'),
            'registration_date': fromMs(r['registration_date'])?.toIso8601String(),
            'payment_method': r['payment_method'],
            'weekly_class_count': r['weekly_class_count'],
            'tuition_fee': r['tuition_fee'],
            'lateness_threshold': r['lateness_threshold'],
            'schedule_notification': intToBool(r['schedule_notification']),
            'attendance_notification': intToBool(r['attendance_notification']),
            'departure_notification': intToBool(r['departure_notification']),
            'lateness_notification': intToBool(r['lateness_notification']),
          }..removeWhere((k, v) => v == null);
        }).toList();
        await supa.from('student_payment_info').upsert(rows, onConflict: 'student_id');
        debugPrint('[BACKFILL][student_payment_info] upserted=${rows.length}');
      } else {
        debugPrint('[BACKFILL][student_payment_info] local=0 (skip)');
      }
    } catch (e, st) {
      debugPrint('[BACKFILL][student_payment_info][ERROR] $e\n$st');
    }
    return validStudentIds;
  }

  static Future<void> _backfillTagEvents(SupabaseClient supa, String academyId) async {
    try {
      // 서버에 이미 있으면 스킵
      final exists = await supa.from('tag_events').select('set_id').eq('academy_id', academyId).limit(1);
      if ((exists as List).isNotEmpty) {
        debugPrint('[BACKFILL][tag_events] server has data -> skip');
        return;
      }
      final local = await AcademyDbService.instance.getAllTagEvents();
      if (local.isEmpty) {
        debugPrint('[BACKFILL][tag_events] local=0 (skip)');
        return;
      }
      final rows = local.map((r) {
        final dynamic col = r['color_value'];
        final int? colorSigned = (col is int) ? col.toSigned(32) : int.tryParse(col?.toString() ?? '')?.toSigned(32);
        return {
          'academy_id': academyId,
          'set_id': r['set_id'],
          'tag_name': r['tag_name'],
          'color_value': colorSigned,
          'icon_code': r['icon_code'],
          'occurred_at': r['timestamp'],
          'note': r['note'],
        }..removeWhere((k, v) => v == null);
      }).toList();
      await supa.from('tag_events').insert(rows);
      debugPrint('[BACKFILL][tag_events] inserted=${rows.length}');
    } catch (e, st) {
      debugPrint('[BACKFILL][tag_events][ERROR] $e\n$st');
    }
  }

  static Future<void> _backfillW5W6W7(SupabaseClient supa, String academyId, [Set<String>? validStudentIds]) async {
    // W5: student_time_blocks
    try {
      final blocks = await AcademyDbService.instance.getStudentTimeBlocks();
      if (blocks.isNotEmpty) {
        final rows = blocks.map((b) {
              final sid = _toUuid(b.studentId, 'students');
              if (validStudentIds != null && validStudentIds.isNotEmpty && !validStudentIds.contains(sid)) {
                return null;
              }
              return {
                'id': _toUuid(b.id, 'student_time_blocks'),
                'academy_id': academyId,
                'student_id': sid,
                'day_index': b.dayIndex,
                'start_hour': b.startHour,
                'start_minute': b.startMinute,
                'duration': b.duration.inMinutes,
                'block_created_at': b.createdAt.toIso8601String(),
                'set_id': b.setId,
                'number': b.number,
                'session_type_id': b.sessionTypeId,
                'weekly_order': b.weeklyOrder,
              };}).whereType<Map<String, dynamic>>().toList();
        await supa.from('student_time_blocks').upsert(rows, onConflict: 'id');
        debugPrint('[BACKFILL][student_time_blocks] upserted=${rows.length}');
      } else {
        debugPrint('[BACKFILL][student_time_blocks] local=0 (skip)');
      }
    } catch (e, st) {
      debugPrint('[BACKFILL][student_time_blocks][ERROR] $e\n$st');
    }

    // W6: attendance_records
    try {
      final rowsLocal = await AcademyDbService.instance.getAttendanceRecords();
      if (rowsLocal.isNotEmpty) {
        String? dt(String? s) => (s == null || s.isEmpty) ? null : DateTime.tryParse(s)?.toIso8601String();
        final rows = rowsLocal.map((r) {
              final sid = _toUuid((r['student_id'] ?? '').toString(), 'students');
              if (validStudentIds != null && validStudentIds.isNotEmpty && !validStudentIds.contains(sid)) {
                return null; // skip invalid FK
              }
              return {
              'id': _toUuid((r['id'] ?? '').toString(), 'attendance_records'),
              'academy_id': academyId,
              'student_id': sid,
              'class_date_time': dt(r['class_date_time'] as String?),
              'class_end_time': dt(r['class_end_time'] as String?),
              'date': (r['date'] as String?)?.substring(0, 10),
              'class_name': r['class_name'],
              'is_present': (r['is_present'] is int) ? ((r['is_present'] as int) != 0) : r['is_present'],
              'arrival_time': dt(r['arrival_time'] as String?),
              'departure_time': dt(r['departure_time'] as String?),
              'notes': r['notes'],
            };
            }).whereType<Map<String, dynamic>>().toList();
        await supa.from('attendance_records').upsert(rows, onConflict: 'id');
        debugPrint('[BACKFILL][attendance_records] upserted=${rows.length}');
      } else {
        debugPrint('[BACKFILL][attendance_records] local=0 (skip)');
      }
    } catch (e, st) {
      debugPrint('[BACKFILL][attendance_records][ERROR] $e\n$st');
    }

    // W7: payment_records
    try {
      final List<PaymentRecord> rowsLocal = await AcademyDbService.instance.getPaymentRecords();
      if (rowsLocal.isNotEmpty) {
        final rows = rowsLocal.map((r) {
              final sid = _toUuid(r.studentId, 'students');
              if (validStudentIds != null && validStudentIds.isNotEmpty && !validStudentIds.contains(sid)) {
                return null;
              }
              return {
              'id': _toUuid('${r.studentId}_${r.dueDate.millisecondsSinceEpoch}_${r.cycle}', 'payment_records'),
              'academy_id': academyId,
              'student_id': sid,
              'cycle': r.cycle,
              'due_date': r.dueDate.toUtc().toIso8601String(),
              'paid_date': r.paidDate?.toUtc().toIso8601String(),
              'postpone_reason': r.postponeReason,
            };}).whereType<Map<String, dynamic>>().toList();
        await supa.from('payment_records').upsert(rows, onConflict: 'id');
        debugPrint('[BACKFILL][payment_records] upserted=${rows.length}');
      } else {
        debugPrint('[BACKFILL][payment_records] local=0 (skip)');
      }
    } catch (e, st) {
      debugPrint('[BACKFILL][payment_records][ERROR] $e\n$st');
    }
  }

  static Future<Set<String>> _fetchServerStudentIds(SupabaseClient supa, String academyId) async {
    try {
      final data = await supa.from('students').select('id').eq('academy_id', academyId);
      final list = (data as List).map((e) => (e['id'] as String).trim()).where((s) => s.isNotEmpty).toSet();
      return list;
    } catch (_) {
      return <String>{};
    }
  }

  static Future<void> _backfillMisc(SupabaseClient supa, String academyId) async {
    // memos
    try {
      final db = await AcademyDbService.instance.db;
      final rowsLocal = await db.query('memos');
      if (rowsLocal.isNotEmpty) {
        String? dt(String? s) => (s == null || s.isEmpty) ? null : DateTime.tryParse(s)?.toIso8601String();
        final rows = rowsLocal.map((r) => {
              'id': _toUuid((r['id'] ?? '').toString(), 'memos'),
              'academy_id': academyId,
              'original': r['original'],
              'summary': r['summary'],
              'scheduled_at': dt(r['scheduled_at'] as String?),
              'dismissed': (r['dismissed'] is int) ? ((r['dismissed'] as int) != 0) : r['dismissed'],
              'recurrence_type': r['recurrence_type'],
              'weekdays': r['weekdays'],
              'recurrence_end': (r['recurrence_end'] as String?)?.substring(0,10),
              'recurrence_count': r['recurrence_count'],
            }).toList();
        await supa.from('memos').upsert(rows, onConflict: 'id');
        debugPrint('[BACKFILL][memos] upserted=${rows.length}');
      }
    } catch (e, st) {
      debugPrint('[BACKFILL][memos][ERROR] $e\n$st');
    }

    // schedule_events
    try {
      final db = await AcademyDbService.instance.db;
      final rowsLocal = await db.query('schedule_events');
      if (rowsLocal.isNotEmpty) {
        final rows = rowsLocal.map((r) {
          final dynamic col = r['color'];
          final int? colorSigned = (col is int) ? col.toSigned(32) : int.tryParse(col?.toString() ?? '')?.toSigned(32);
          return {
            'id': _toUuid((r['id'] ?? '').toString(), 'schedule_events'),
            'academy_id': academyId,
            'group_id': r['group_id'],
            'date': (r['date'] as String?)?.substring(0,10),
            'title': r['title'],
            'note': r['note'],
            'start_hour': r['start_hour'],
            'start_minute': r['start_minute'],
            'end_hour': r['end_hour'],
            'end_minute': r['end_minute'],
            'color': colorSigned,
            'tags': r['tags'],
            'icon_key': r['icon_key'],
          }..removeWhere((k, v) => v == null);
        }).toList();
        await supa.from('schedule_events').upsert(rows, onConflict: 'id');
        debugPrint('[BACKFILL][schedule_events] upserted=${rows.length}');
      }
    } catch (e, st) {
      debugPrint('[BACKFILL][schedule_events][ERROR] $e\n$st');
    }

    // resource_grades
    try {
      final rowsLocal = await AcademyDbService.instance.getResourceGrades();
      if (rowsLocal.isNotEmpty) {
        final rows = rowsLocal.map((r) => {
              'academy_id': academyId,
              'name': r['name'],
              'order_index': r['order_index'],
            }).toList();
        await supa.from('resource_grades').upsert(rows, onConflict: 'academy_id,name');
        debugPrint('[BACKFILL][resource_grades] upserted=${rows.length}');
      }
    } catch (e, st) {
      debugPrint('[BACKFILL][resource_grades][ERROR] $e\n$st');
    }

    // resource_grade_icons
    try {
      final rowsLocal = await AcademyDbService.instance.getResourceGradeIcons();
      if (rowsLocal.isNotEmpty) {
        final rows = rowsLocal.entries.map((e) => {
              'academy_id': academyId,
              'name': e.key,
              'icon': e.value,
            }).toList();
        await supa.from('resource_grade_icons').upsert(rows, onConflict: 'academy_id,name');
        debugPrint('[BACKFILL][resource_grade_icons] upserted=${rows.length}');
      }
    } catch (e, st) {
      debugPrint('[BACKFILL][resource_grade_icons][ERROR] $e\n$st');
    }

    // resource_file_links
    try {
      final db = await AcademyDbService.instance.db;
      final links = await db.query('resource_file_links');
      if (links.isNotEmpty) {
        final rows = links.map((r) => {
              'academy_id': academyId,
              'file_id': _toUuid((r['file_id'] ?? '').toString(), 'resource_files'),
              'grade': r['grade'],
              'url': r['url'],
            }).toList();
        await supa.from('resource_file_links').insert(rows);
        debugPrint('[BACKFILL][resource_file_links] inserted=${rows.length}');
      }
    } catch (e, st) {
      debugPrint('[BACKFILL][resource_file_links][ERROR] $e\n$st');
    }

    // resource_file_bookmarks
    try {
      final db = await AcademyDbService.instance.db;
      final bk = await db.query('resource_file_bookmarks');
      if (bk.isNotEmpty) {
        final rows = bk.map((r) => {
              'academy_id': academyId,
              'file_id': _toUuid((r['file_id'] ?? '').toString(), 'resource_files'),
              'name': r['name'],
              'description': r['description'],
              'path': r['path'],
              'order_index': r['order_index'],
            }).toList();
        await supa.from('resource_file_bookmarks').insert(rows);
        debugPrint('[BACKFILL][resource_file_bookmarks] inserted=${rows.length}');
      }
    } catch (e, st) {
      debugPrint('[BACKFILL][resource_file_bookmarks][ERROR] $e\n$st');
    }
  }
}


