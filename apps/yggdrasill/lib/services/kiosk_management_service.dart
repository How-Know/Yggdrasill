import 'package:supabase_flutter/supabase_flutter.dart';

import 'tenant_service.dart';

class KioskDevice {
  const KioskDevice({
    required this.id,
    required this.deviceId,
    required this.deviceName,
    required this.isActive,
    required this.pairedAt,
    required this.lastSeenAt,
  });

  factory KioskDevice.fromJson(Map<String, dynamic> json) {
    return KioskDevice(
      id: json['id']?.toString() ?? '',
      deviceId: json['device_id']?.toString() ?? '',
      deviceName: json['device_name']?.toString() ?? '이름 없는 기기',
      isActive: json['is_active'] == true,
      pairedAt: _dateTime(json['paired_at']),
      lastSeenAt: _dateTime(json['last_seen_at']),
    );
  }

  final String id;
  final String deviceId;
  final String deviceName;
  final bool isActive;
  final DateTime? pairedAt;
  final DateTime? lastSeenAt;
}

class KioskAnnouncement {
  const KioskAnnouncement({
    required this.id,
    required this.title,
    required this.body,
    required this.publishedAt,
    required this.expiresAt,
    required this.isActive,
  });

  factory KioskAnnouncement.fromJson(Map<String, dynamic> json) {
    return KioskAnnouncement(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      body: json['body']?.toString() ?? '',
      publishedAt: _dateTime(json['published_at']),
      expiresAt: _dateTime(json['expires_at']),
      isActive: json['is_active'] == true,
    );
  }

  final String id;
  final String title;
  final String body;
  final DateTime? publishedAt;
  final DateTime? expiresAt;
  final bool isActive;

  bool get isCurrentlyActive {
    final expiry = expiresAt;
    return isActive && (expiry == null || expiry.isAfter(DateTime.now()));
  }
}

class KioskManagementException implements Exception {
  const KioskManagementException(this.message);

  final String message;

  @override
  String toString() => message;
}

class KioskManagementService {
  KioskManagementService._();

  static final KioskManagementService instance = KioskManagementService._();

  SupabaseClient get _client => Supabase.instance.client;

  Future<String> _academyId() async {
    final academyId =
        (await TenantService.instance.ensureActiveAcademy()).trim();
    if (academyId.isEmpty) {
      throw const KioskManagementException('활성 학원 정보를 찾지 못했습니다.');
    }
    return academyId;
  }

  Future<void> approvePairing(String code) async {
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      throw const KioskManagementException('연결 PIN 6자리를 입력해 주세요.');
    }
    try {
      final result = await _client.rpc(
        'kiosk_approve_pairing',
        params: {
          'p_academy_id': await _academyId(),
          'p_code': code,
        },
      );
      final response = _asMap(result);
      if (response['ok'] != true) {
        throw KioskManagementException(
          _localizedError(response['error']?.toString()),
        );
      }
    } on KioskManagementException {
      rethrow;
    } catch (error) {
      throw KioskManagementException(_localizedException(error));
    }
  }

  Future<List<KioskDevice>> listDevices() async {
    try {
      final result = await _client.rpc(
        'kiosk_list_devices',
        params: {'p_academy_id': await _academyId()},
      );
      return _asRows(result).map(KioskDevice.fromJson).toList();
    } catch (error) {
      throw KioskManagementException(_localizedException(error));
    }
  }

  Future<List<KioskAnnouncement>> listAnnouncements({
    bool includeInactive = true,
  }) async {
    try {
      final result = await _client.rpc(
        'kiosk_list_announcements',
        params: {
          'p_academy_id': await _academyId(),
          'p_include_inactive': includeInactive,
        },
      );
      return _asRows(result).map(KioskAnnouncement.fromJson).toList();
    } catch (error) {
      throw KioskManagementException(_localizedException(error));
    }
  }

  Future<void> createAnnouncement({
    required String title,
    required String body,
    DateTime? expiresAt,
  }) async {
    final cleanTitle = title.trim();
    final cleanBody = body.trim();
    if (cleanTitle.isEmpty || cleanTitle.length > 200) {
      throw const KioskManagementException('제목은 1~200자로 입력해 주세요.');
    }
    if (cleanBody.isEmpty || cleanBody.length > 10000) {
      throw const KioskManagementException('본문은 1~10,000자로 입력해 주세요.');
    }

    final publishedAt = DateTime.now().toUtc();
    try {
      await _client.rpc(
        'kiosk_create_announcement',
        params: {
          'p_academy_id': await _academyId(),
          'p_title': cleanTitle,
          'p_body': cleanBody,
          'p_published_at': publishedAt.toIso8601String(),
          'p_expires_at': expiresAt?.toUtc().toIso8601String(),
          'p_is_active': true,
        },
      );
    } catch (error) {
      throw KioskManagementException(_localizedException(error));
    }
  }

  Future<void> updateAnnouncement(
    String announcementId,
    Map<String, dynamic> patch,
  ) async {
    try {
      await _client.rpc(
        'kiosk_update_announcement',
        params: {
          'p_announcement_id': announcementId,
          'p_patch': patch,
        },
      );
    } catch (error) {
      throw KioskManagementException(_localizedException(error));
    }
  }

  Future<void> endAnnouncement(String announcementId) async {
    try {
      await _client.rpc(
        'kiosk_end_announcement',
        params: {'p_announcement_id': announcementId},
      );
    } catch (error) {
      throw KioskManagementException(_localizedException(error));
    }
  }

  Future<void> deleteAnnouncement(String announcementId) async {
    try {
      await _client.rpc(
        'kiosk_delete_announcement',
        params: {'p_announcement_id': announcementId},
      );
    } catch (error) {
      throw KioskManagementException(_localizedException(error));
    }
  }

  static List<Map<String, dynamic>> _asRows(dynamic value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  }

  static Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    throw const KioskManagementException('서버 응답 형식이 올바르지 않습니다.');
  }

  static String _localizedException(Object error) {
    if (error is KioskManagementException) return error.message;
    final raw = error.toString().toLowerCase();
    if (raw.contains('not_a_member') || raw.contains('42501')) {
      return '이 학원의 키오스크를 관리할 권한이 없습니다.';
    }
    if (raw.contains('announcement_not_found') || raw.contains('p0002')) {
      return '공지를 찾을 수 없습니다. 목록을 새로고침해 주세요.';
    }
    if (raw.contains('socket') ||
        raw.contains('network') ||
        raw.contains('connection')) {
      return '네트워크 연결을 확인한 뒤 다시 시도해 주세요.';
    }
    return '요청을 처리하지 못했습니다. 잠시 후 다시 시도해 주세요.';
  }

  static String _localizedError(String? code) {
    switch (code) {
      case 'pairing_not_found':
        return 'PIN을 찾을 수 없습니다. 키오스크 화면의 PIN을 확인해 주세요.';
      case 'pairing_expired':
        return 'PIN이 만료되었습니다. 키오스크에서 새 PIN을 발급해 주세요.';
      case 'pairing_already_approved':
        return '이미 다른 학원에서 승인한 PIN입니다.';
      default:
        return '기기 연결을 승인하지 못했습니다.';
    }
  }
}

DateTime? _dateTime(dynamic value) {
  if (value == null) return null;
  return DateTime.tryParse(value.toString())?.toLocal();
}
