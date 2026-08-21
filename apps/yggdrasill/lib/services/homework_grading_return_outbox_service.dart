import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'academy_db.dart';

typedef HomeworkGradingReturnKey = ({String studentId, String itemId});

class HomeworkGradingReturnDraft {
  const HomeworkGradingReturnDraft({
    required this.id,
    required this.studentId,
    required this.groupId,
    required this.action,
    required this.payload,
    required this.createdAt,
    this.attemptCount = 0,
    this.lastError,
  });

  final String id;
  final String studentId;
  final String groupId;
  final String action;
  final Map<String, dynamic> payload;
  final DateTime createdAt;
  final int attemptCount;
  final String? lastError;

  List<String> get itemIds =>
      (payload['homework_item_ids'] as List? ?? const [])
          .map((value) => '$value'.trim())
          .where((value) => value.isNotEmpty)
          .toList(growable: false);

  bool get markCompleted => action == 'complete';

  Set<HomeworkGradingReturnKey> get keys => {
        for (final itemId in itemIds) (studentId: studentId, itemId: itemId),
      };
}

class HomeworkGradingReturnProcessResult {
  const HomeworkGradingReturnProcessResult({
    required this.succeededKeys,
    required this.failedKeys,
  });

  final Set<HomeworkGradingReturnKey> succeededKeys;
  final Set<HomeworkGradingReturnKey> failedKeys;
}

/// 구조화 채점은 확인 시 로컬에만 보관하고, 반환 시 서버 트랜잭션으로 커밋한다.
///
/// SQLite outbox를 사용하므로 앱이 종료되거나 네트워크가 끊겨도 반환 대상이
/// 사라지지 않는다. 서버 RPC는 draft id를 idempotency key로 사용한다.
class HomeworkGradingReturnOutboxService {
  HomeworkGradingReturnOutboxService._();

  static final HomeworkGradingReturnOutboxService instance =
      HomeworkGradingReturnOutboxService._();

  final Map<String, HomeworkGradingReturnDraft> _draftsById = {};
  bool _initialized = false;
  Future<void>? _initializing;

  Iterable<HomeworkGradingReturnDraft> get drafts => _draftsById.values;

  Future<void> initialize() {
    if (_initialized) return Future.value();
    return _initializing ??= _load().whenComplete(() => _initializing = null);
  }

  Future<void> _load() async {
    final db = await AcademyDbService.instance.db;
    await db.execute('''
      CREATE TABLE IF NOT EXISTS homework_grading_return_outbox (
        id TEXT PRIMARY KEY,
        student_id TEXT NOT NULL,
        group_id TEXT NOT NULL,
        action TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        attempt_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_homework_grading_return_outbox_status
      ON homework_grading_return_outbox(status, created_at)
    ''');
    await db.update(
      'homework_grading_return_outbox',
      {
        'status': 'pending',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: "status = 'processing'",
    );
    final rows = await db.query(
      'homework_grading_return_outbox',
      where: "status IN ('pending', 'failed')",
      orderBy: 'created_at ASC',
    );
    _draftsById.clear();
    for (final row in rows) {
      try {
        final draft = _fromRow(row);
        _draftsById[draft.id] = draft;
      } catch (error) {
        debugPrint('[GRADING_RETURN_OUTBOX][decode] $error');
        await db.update(
          'homework_grading_return_outbox',
          {
            'status': 'failed',
            'last_error': 'invalid_local_payload: $error',
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [row['id']],
        );
      }
    }
    _initialized = true;
  }

  HomeworkGradingReturnDraft _fromRow(Map<String, Object?> row) {
    final payloadRaw = '${row['payload_json'] ?? '{}'}';
    final decoded = jsonDecode(payloadRaw);
    return HomeworkGradingReturnDraft(
      id: '${row['id'] ?? ''}'.trim(),
      studentId: '${row['student_id'] ?? ''}'.trim(),
      groupId: '${row['group_id'] ?? ''}'.trim(),
      action: '${row['action'] ?? ''}'.trim(),
      payload: decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{},
      createdAt: DateTime.tryParse('${row['created_at'] ?? ''}')?.toLocal() ??
          DateTime.now(),
      attemptCount: (row['attempt_count'] as num?)?.toInt() ?? 0,
      lastError: row['last_error'] as String?,
    );
  }

  Map<HomeworkGradingReturnKey, bool> pendingValues() {
    return {
      for (final draft in _draftsById.values)
        for (final key in draft.keys) key: draft.markCompleted,
    };
  }

  Set<HomeworkGradingReturnKey> structuredKeys() {
    return {
      for (final draft in _draftsById.values) ...draft.keys,
    };
  }

  bool containsAny(Iterable<HomeworkGradingReturnKey> keys) {
    final wanted = keys.toSet();
    return _draftsById.values.any(
      (draft) => draft.keys.any(wanted.contains),
    );
  }

  Future<void> enqueue(Map<String, dynamic> payload) async {
    await initialize();
    final id = '${payload['request_id'] ?? ''}'.trim();
    final studentId = '${payload['student_id'] ?? ''}'.trim();
    final groupId = '${payload['group_id'] ?? ''}'.trim();
    final action = '${payload['action'] ?? ''}'.trim();
    if (id.isEmpty ||
        studentId.isEmpty ||
        groupId.isEmpty ||
        (action != 'complete' && action != 'confirm')) {
      throw ArgumentError('invalid grading return draft');
    }
    final now = DateTime.now();
    final draft = HomeworkGradingReturnDraft(
      id: id,
      studentId: studentId,
      groupId: groupId,
      action: action,
      payload: Map<String, dynamic>.from(payload),
      createdAt: now,
    );
    final draftKeys = draft.keys;
    final replacedIds = _draftsById.values
        .where((existing) => existing.keys.any(draftKeys.contains))
        .map((existing) => existing.id)
        .toList(growable: false);
    final db = await AcademyDbService.instance.db;
    await db.transaction((txn) async {
      if (replacedIds.isNotEmpty) {
        await txn.delete(
          'homework_grading_return_outbox',
          where: 'id IN (${List.filled(replacedIds.length, '?').join(',')})',
          whereArgs: replacedIds,
        );
      }
      await txn.insert(
        'homework_grading_return_outbox',
        {
          'id': id,
          'student_id': studentId,
          'group_id': groupId,
          'action': action,
          'payload_json': jsonEncode(payload),
          'status': 'pending',
          'attempt_count': 0,
          'last_error': null,
          'created_at': now.toUtc().toIso8601String(),
          'updated_at': now.toUtc().toIso8601String(),
        },
      );
    });
    await _load();
  }

  Future<void> removeForKeys(Iterable<HomeworkGradingReturnKey> keys) async {
    await initialize();
    final wanted = keys.toSet();
    final ids = _draftsById.values
        .where((draft) => draft.keys.any(wanted.contains))
        .map((draft) => draft.id)
        .toList(growable: false);
    if (ids.isEmpty) return;
    final db = await AcademyDbService.instance.db;
    await db.delete(
      'homework_grading_return_outbox',
      where: 'id IN (${List.filled(ids.length, '?').join(',')})',
      whereArgs: ids,
    );
    for (final id in ids) {
      _draftsById.remove(id);
    }
  }

  Future<HomeworkGradingReturnProcessResult> processForKeys(
    Iterable<HomeworkGradingReturnKey> keys,
  ) async {
    await initialize();
    final wanted = keys.toSet();
    final selected = _draftsById.values
        .where((draft) => draft.keys.any(wanted.contains))
        .toList(growable: false);
    final succeeded = <HomeworkGradingReturnKey>{};
    final failed = <HomeworkGradingReturnKey>{};
    for (final draft in selected) {
      final ok = await _commit(draft);
      if (ok) {
        succeeded.addAll(draft.keys);
      } else {
        failed.addAll(draft.keys);
      }
    }
    return HomeworkGradingReturnProcessResult(
      succeededKeys: succeeded,
      failedKeys: failed,
    );
  }

  Future<bool> _commit(HomeworkGradingReturnDraft draft) async {
    final db = await AcademyDbService.instance.db;
    final nowIso = DateTime.now().toUtc().toIso8601String();
    await db.update(
      'homework_grading_return_outbox',
      {'status': 'processing', 'updated_at': nowIso},
      where: 'id = ?',
      whereArgs: [draft.id],
    );
    try {
      final raw = await Supabase.instance.client.rpc(
        'homework_commit_structured_grading_return_v2',
        params: {'p_payload': draft.payload},
      );
      final row =
          raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
      if (row['ok'] != true) {
        throw StateError('${row['reason'] ?? 'return_commit_failed'}');
      }
      await db.delete(
        'homework_grading_return_outbox',
        where: 'id = ?',
        whereArgs: [draft.id],
      );
      _draftsById.remove(draft.id);
      return true;
    } catch (error, stackTrace) {
      debugPrint('[GRADING_RETURN_OUTBOX][commit] $error\n$stackTrace');
      await db.update(
        'homework_grading_return_outbox',
        {
          'status': 'failed',
          'attempt_count': draft.attemptCount + 1,
          'last_error': '$error',
          'updated_at': nowIso,
        },
        where: 'id = ?',
        whereArgs: [draft.id],
      );
      await _load();
      return false;
    }
  }
}
