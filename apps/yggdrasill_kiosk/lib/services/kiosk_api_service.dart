import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../models/kiosk_models.dart';

class KioskConfigurationException implements Exception {
  const KioskConfigurationException(this.message);
  final String message;
  @override
  String toString() => message;
}

class KioskApiException implements Exception {
  const KioskApiException(this.message, {this.code = '', this.statusCode});
  final String message;
  final String code;
  final int? statusCode;
  @override
  String toString() => message;
}

class KioskApiService {
  KioskApiService({
    required this.baseUrl,
    required this.anonKey,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final String anonKey;
  final http.Client _client;

  static Future<KioskApiService> create() async {
    const defineUrl = String.fromEnvironment('SUPABASE_URL');
    const defineKey = String.fromEnvironment('SUPABASE_ANON_KEY');
    final url = defineUrl.trim();
    final key = defineKey.trim();

    if (url.isEmpty || key.isEmpty) {
      throw const KioskConfigurationException(
        '키오스크 연결 설정이 없습니다.\n'
        'tool/run_windows.ps1로 실행하거나 SUPABASE_URL과 '
        'SUPABASE_ANON_KEY를 --dart-define으로 전달해 주세요.',
      );
    }
    return KioskApiService(
      baseUrl: url.replaceFirst(RegExp(r'/$'), ''),
      anonKey: key,
    );
  }

  Uri get _endpoint => Uri.parse('$baseUrl/functions/v1/kiosk_api');

  String _errorMessage(String code, JsonMap payload, int statusCode) {
    switch (code) {
      case 'pairing_pending':
        return '관리자 승인을 기다리고 있습니다.';
      case 'pairing_not_found':
        return '연결 PIN을 찾을 수 없습니다.';
      case 'pairing_expired':
        return '연결 PIN이 만료되었습니다.';
      case 'invalid_token':
        return '기기 연결이 만료되었습니다.';
      case 'pin_setup_required':
        return '학생 PIN이 아직 설정되지 않았습니다.';
      case 'pin_invalid':
        final attempts = payload['attempts_left'];
        return attempts == null
            ? 'PIN이 올바르지 않습니다.'
            : 'PIN이 올바르지 않습니다. ($attempts회 남음)';
      case 'pin_locked':
        final seconds = payload['locked_seconds'];
        return seconds == null
            ? 'PIN 입력이 잠시 잠겼습니다.'
            : 'PIN 입력이 잠겼습니다. $seconds초 후 다시 시도해 주세요.';
      case 'already_checked_in':
        return '이미 등원 처리된 학생입니다.';
      case 'not_scheduled':
        return '오늘 예정에 없는 학생입니다. 추가수업으로 다시 시도해 주세요.';
      case 'student_not_found':
        return '학생 정보를 찾을 수 없습니다.';
      default:
        return stringFor(payload, const [
          'message',
          'detail',
          'error_description',
        ], '서버 요청에 실패했습니다. ($statusCode)');
    }
  }

  Future<JsonMap> _call(
    String action, {
    JsonMap body = const {},
    KioskSession? session,
  }) async {
    final payload = <String, dynamic>{
      'action': action,
      ...body,
      if (session != null) ...{
        'token': session.token,
        'device_token': session.token,
        'device_id': session.deviceId,
        'deviceId': session.deviceId,
      },
    };
    http.Response response;
    try {
      response = await _client
          .post(
            _endpoint,
            headers: {
              'Content-Type': 'application/json',
              'apikey': anonKey,
              'Authorization': 'Bearer $anonKey',
              if (session != null) 'X-Kiosk-Token': session.token,
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      throw const KioskApiException(
        '네트워크에 연결할 수 없습니다. 잠시 후 다시 시도해 주세요.',
        code: 'network',
      );
    }

    JsonMap decoded = {};
    try {
      final value = jsonDecode(utf8.decode(response.bodyBytes));
      if (value is Map) decoded = Map<String, dynamic>.from(value);
    } catch (_) {
      if (response.statusCode >= 200 && response.statusCode < 300) {
        throw const KioskApiException('서버 응답을 해석하지 못했습니다.');
      }
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = mapFor(decoded, const ['error']) ?? decoded;
      final code = stringFor(error, const [
        'code',
        'error_code',
        'error',
      ], stringFor(decoded, const ['error']));
      throw KioskApiException(
        _errorMessage(code, decoded, response.statusCode),
        code: code,
        statusCode: response.statusCode,
      );
    }
    return decoded;
  }

  Future<PairingState> beginPairing({
    required String deviceId,
    required String deviceName,
  }) async {
    final json = await _call(
      'begin_pairing',
      body: {'device_id': deviceId, 'device_name': deviceName},
    );
    final state = PairingState.fromJson(json).withPairingId(deviceId);
    if (state.pin.isEmpty) {
      throw const KioskApiException('연결 PIN을 받지 못했습니다.');
    }
    return state;
  }

  Future<KioskSession?> pollPairing(PairingState pairing) async {
    final json = await _call(
      'poll_pairing',
      body: {'device_id': pairing.pairingId, 'code': pairing.pin},
    );
    final root = mapFor(json, const ['data', 'result', 'device']) ?? json;
    final token = stringFor(root, const [
      'token',
      'device_token',
      'deviceToken',
      'kiosk_token',
    ]);
    final deviceId = stringFor(root, const [
      'device_id',
      'deviceId',
      'id',
      'kiosk_id',
    ], pairing.pairingId);
    if (token.isEmpty || deviceId.isEmpty) return null;
    return KioskSession(deviceId: deviceId, token: token);
  }

  Future<BootstrapData> bootstrap(KioskSession session) async =>
      BootstrapData.fromJson(await _call('bootstrap', session: session));

  Future<List<StudentVisit>> listToday(KioskSession session) async {
    final json = await _call('list_today', session: session);
    final root = mapFor(json, const ['data', 'result']) ?? json;
    final values = listFor(root, const [
      'students',
      'items',
      'visits',
      'schedules',
      'results',
      'data',
    ]);
    final students = values
        .whereType<Map>()
        .map((item) => StudentVisit.fromJson(Map<String, dynamic>.from(item)))
        .toList();
    students.sort((a, b) => a.timeLabel.compareTo(b.timeLabel));
    return students;
  }

  Future<List<StudentVisit>> searchStudents(
    KioskSession session,
    String query,
  ) async {
    final json = await _call(
      'search_students',
      session: session,
      body: {'query': query, 'q': query},
    );
    final root = mapFor(json, const ['data', 'result']) ?? json;
    return listFor(root, const ['students', 'items', 'results', 'data'])
        .whereType<Map>()
        .map(
          (item) => StudentVisit.fromJson(
            Map<String, dynamic>.from(item),
          ).copyWith(scheduledToday: false),
        )
        .toList();
  }

  Future<CheckInResult> checkIn(
    KioskSession session,
    StudentVisit student,
    String pin,
  ) async {
    final requestId =
        '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
    try {
      final json = await _call(
        'check_in',
        session: session,
        body: {
          'student_id': student.id,
          'studentId': student.id,
          'pin': pin,
          'request_id': requestId,
          'walk_in': !student.scheduledToday,
        },
      );
      return CheckInResult.fromJson(json);
    } on KioskApiException catch (error) {
      return CheckInResult(
        success: false,
        code: error.code,
        message: error.message,
      );
    }
  }
}
