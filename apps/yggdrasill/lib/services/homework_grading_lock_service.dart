import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'homework_grading_return_outbox_service.dart';
import 'tenant_service.dart';

typedef HomeworkGradingLockKey = ({String studentId, String itemId});

class HomeworkGradingLockAccess {
  const HomeworkGradingLockAccess({
    required this.canEdit,
    required this.targetKey,
    this.ownerName = '',
  });

  final bool canEdit;
  final String targetKey;
  final String ownerName;

  String get readOnlyReason {
    final safeName = ownerName.trim();
    return safeName.isEmpty ? '다른 선생님이 채점 중입니다.' : '$safeName 선생님이 채점 중입니다.';
  }
}

class _OwnedGradingLease {
  const _OwnedGradingLease({
    required this.academyId,
    required this.studentId,
    required this.groupId,
    required this.targetKey,
    required this.token,
    required this.keys,
  });

  final String academyId;
  final String studentId;
  final String groupId;
  final String targetKey;
  final String token;
  final Set<HomeworkGradingLockKey> keys;
}

/// 서버 임대형 구조화 채점 잠금.
///
/// 채점지를 닫아도 로컬 반환 초안이 남아 있으면 lease를 유지한다. 반환 성공,
/// 초안 취소, 또는 초안 없는 시트 닫기에서 해제한다. 앱이 죽으면 heartbeat가
/// 멈추고 서버 lease가 만료되어 영구 잠금이 남지 않는다.
class HomeworkGradingLockService {
  HomeworkGradingLockService._();

  static final HomeworkGradingLockService instance =
      HomeworkGradingLockService._();

  static const _leaseSeconds = 180;
  static const _heartbeatInterval = Duration(seconds: 45);

  final Map<String, _OwnedGradingLease> _ownedByTarget = {};
  final Map<HomeworkGradingLockKey, String> _targetByKey = {};
  Timer? _heartbeatTimer;

  /// 시트 닫기 뒤 서버 lease 해제가 진행 중인 과제.
  final ValueNotifier<Set<HomeworkGradingLockKey>> releasingKeys =
      ValueNotifier<Set<HomeworkGradingLockKey>>(<HomeworkGradingLockKey>{});

  Future<HomeworkGradingLockAccess> acquire({
    required String studentId,
    required String groupId,
    required Iterable<HomeworkGradingLockKey> keys,
    String? preferredToken,
  }) async {
    final safeStudentId = studentId.trim();
    final safeGroupId = groupId.trim();
    final safeKeys = keys
        .where((key) =>
            key.studentId.trim().isNotEmpty && key.itemId.trim().isNotEmpty)
        .toSet();
    if (safeStudentId.isEmpty || safeGroupId.isEmpty || safeKeys.isEmpty) {
      return const HomeworkGradingLockAccess(
        canEdit: false,
        targetKey: '',
        ownerName: '',
      );
    }

    final targetKey = 'group:$safeGroupId';
    final existing = _ownedByTarget[targetKey];
    if (existing != null) {
      final mergedKeys = <HomeworkGradingLockKey>{
        ...existing.keys,
        ...safeKeys,
      };
      final merged = _OwnedGradingLease(
        academyId: existing.academyId,
        studentId: existing.studentId,
        groupId: existing.groupId,
        targetKey: existing.targetKey,
        token: existing.token,
        keys: mergedKeys,
      );
      _ownedByTarget[targetKey] = merged;
      for (final key in mergedKeys) {
        _targetByKey[key] = targetKey;
      }
      return HomeworkGradingLockAccess(
        canEdit: true,
        targetKey: targetKey,
      );
    }

    final academyId = (await TenantService.instance.getActiveAcademyId()) ??
        await TenantService.instance.ensureActiveAcademy();
    final token = (preferredToken ?? '').trim().isNotEmpty
        ? preferredToken!.trim()
        : const Uuid().v4();
    final raw = await Supabase.instance.client.rpc(
      'homework_grading_lock_acquire_v1',
      params: {
        'p_academy_id': academyId,
        'p_student_id': safeStudentId,
        'p_group_id': safeGroupId,
        'p_homework_item_ids':
            safeKeys.map((key) => key.itemId).toSet().toList(growable: false),
        'p_session_token': token,
        'p_lease_seconds': _leaseSeconds,
      },
    );
    final row =
        raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    final acquired = row['acquired'] == true;
    final ownerName = '${row['owner_name'] ?? ''}'.trim();
    if (!acquired) {
      return HomeworkGradingLockAccess(
        canEdit: false,
        targetKey: targetKey,
        ownerName: ownerName,
      );
    }

    final lease = _OwnedGradingLease(
      academyId: academyId,
      studentId: safeStudentId,
      groupId: safeGroupId,
      targetKey: targetKey,
      token: token,
      keys: safeKeys,
    );
    _ownedByTarget[targetKey] = lease;
    for (final key in safeKeys) {
      _targetByKey[key] = targetKey;
    }
    _ensureHeartbeat();
    return HomeworkGradingLockAccess(
      canEdit: true,
      targetKey: targetKey,
    );
  }

  Map<String, dynamic> attachOwnedLockToken(Map<String, dynamic> payload) {
    final groupId = '${payload['group_id'] ?? ''}'.trim();
    final lease = _ownedByTarget['group:$groupId'];
    if (lease == null) return Map<String, dynamic>.from(payload);
    return <String, dynamic>{
      ...payload,
      'grading_lock_token': lease.token,
    };
  }

  Future<void> restoreDraftLeases() async {
    await HomeworkGradingReturnOutboxService.instance.initialize();
    for (final draft in HomeworkGradingReturnOutboxService.instance.drafts) {
      final groupId = draft.groupId.trim();
      final token = '${draft.payload['grading_lock_token'] ?? ''}'.trim();
      if (groupId.isEmpty || token.isEmpty || draft.keys.isEmpty) continue;
      try {
        await acquire(
          studentId: draft.studentId,
          groupId: groupId,
          keys: draft.keys,
          preferredToken: token,
        );
      } catch (error) {
        debugPrint('[GRADING_LOCK][restore] $error');
      }
    }
  }

  Future<void> releaseIfNoDraft(
    Iterable<HomeworkGradingLockKey> keys,
  ) async {
    final list = keys.toList(growable: false);
    await HomeworkGradingReturnOutboxService.instance.initialize();
    if (HomeworkGradingReturnOutboxService.instance.containsAny(list)) return;
    final releasing = _leasedKeys(list);
    if (releasing.isEmpty) {
      await releaseForKeys(list);
      return;
    }
    _markReleasing(releasing);
    try {
      await releaseForKeys(list);
    } finally {
      _unmarkReleasing(releasing);
    }
  }

  Set<HomeworkGradingLockKey> _leasedKeys(
    Iterable<HomeworkGradingLockKey> keys,
  ) {
    final leased = <HomeworkGradingLockKey>{};
    for (final key in keys) {
      final target = _targetByKey[key];
      if (target != null && _ownedByTarget.containsKey(target)) {
        leased.add(key);
      }
    }
    return leased;
  }

  void _markReleasing(Set<HomeworkGradingLockKey> keys) {
    releasingKeys.value = <HomeworkGradingLockKey>{
      ...releasingKeys.value,
      ...keys,
    };
  }

  void _unmarkReleasing(Set<HomeworkGradingLockKey> keys) {
    releasingKeys.value = <HomeworkGradingLockKey>{
      ...releasingKeys.value,
    }..removeAll(keys);
  }

  Future<void> releaseForKeys(
    Iterable<HomeworkGradingLockKey> keys,
  ) async {
    final targets = <String>{
      for (final key in keys)
        if (_targetByKey[key] != null) _targetByKey[key]!,
    };
    for (final target in targets) {
      final lease = _ownedByTarget[target];
      if (lease == null) continue;
      try {
        await Supabase.instance.client.rpc(
          'homework_grading_lock_release_v1',
          params: {
            'p_academy_id': lease.academyId,
            'p_target_key': lease.targetKey,
            'p_session_token': lease.token,
          },
        );
      } catch (error) {
        debugPrint('[GRADING_LOCK][release] $error');
      }
      _forgetLease(lease);
    }
  }

  void forgetKeys(Iterable<HomeworkGradingLockKey> keys) {
    final targets = <String>{
      for (final key in keys)
        if (_targetByKey[key] != null) _targetByKey[key]!,
    };
    for (final target in targets) {
      final lease = _ownedByTarget[target];
      if (lease != null) _forgetLease(lease);
    }
  }

  void _forgetLease(_OwnedGradingLease lease) {
    _ownedByTarget.remove(lease.targetKey);
    for (final key in lease.keys) {
      if (_targetByKey[key] == lease.targetKey) {
        _targetByKey.remove(key);
      }
    }
    if (_ownedByTarget.isEmpty) {
      _heartbeatTimer?.cancel();
      _heartbeatTimer = null;
    }
  }

  void _ensureHeartbeat() {
    _heartbeatTimer ??= Timer.periodic(
      _heartbeatInterval,
      (_) => unawaited(_heartbeat()),
    );
  }

  Future<void> _heartbeat() async {
    final leases = _ownedByTarget.values.toList(growable: false);
    for (final lease in leases) {
      try {
        final alive = await Supabase.instance.client.rpc(
          'homework_grading_lock_heartbeat_v1',
          params: {
            'p_academy_id': lease.academyId,
            'p_target_key': lease.targetKey,
            'p_session_token': lease.token,
            'p_lease_seconds': _leaseSeconds,
          },
        );
        if (alive != true) _forgetLease(lease);
      } catch (error) {
        debugPrint('[GRADING_LOCK][heartbeat] $error');
      }
    }
  }
}
