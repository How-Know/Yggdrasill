import 'dart:convert';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/attendance_record.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import '../services/data_manager.dart';
import 'kakao_reservation_service.dart';
import 'package:uuid/uuid.dart';

class SyncService {
  SyncService._internal();
  static final SyncService instance = SyncService._internal();

  static const String _initialFlagKey = 'initial_sync_done_v2';
  static const String _studentsSyncPrefKey = 'enable_students_sync';

  Future<void> runInitialSyncIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    final done = prefs.getBool(_initialFlagKey) ?? false;
    if (done) return;
    // baseUrl 또는 토큰이 준비되지 않은 상태라면 보류하고 플래그를 설정하지 않는다.
    final baseUrl = await KakaoReservationService.instance.getBaseUrl();
    if (baseUrl == null || baseUrl.isEmpty) {
      return;
    }
    final studentsOk = await _maybeSyncStudents();
    final attendanceOk = await _syncAttendance(days: 49); // 최근 7주
    if (studentsOk && attendanceOk) {
      await prefs.setBool(_initialFlagKey, true);
    }
  }

  Future<void> manualSync({int days = 49}) async {
    // 최신 로컬 데이터 적재 보장
    try {
      await DataManager.instance.loadAttendanceRecords();
      // ignore: avoid_print
      print('[SYNC][manual] local attendance loaded: ${DataManager.instance.attendanceRecords.length}');
    } catch (_) {}
    await _maybeSyncStudents();
    await _syncAttendance(days: days);
  }

  Future<bool> _maybeSyncStudents() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool(_studentsSyncPrefKey) ?? false;
      if (!enabled) return true; // 동기화 비활성화: 성공으로 간주
      return await _syncStudents();
    } catch (_) {
      return false;
    }
  }

  Future<void> resetInitialSyncFlag() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_initialFlagKey);
  }

  Future<bool> _syncStudents() async {
    final baseUrl = await KakaoReservationService.instance.getBaseUrl();
    if (baseUrl == null || baseUrl.isEmpty) {
      // ignore: avoid_print
      print('[SYNC][students][SKIP] baseUrl not configured');
      return false;
    }
    final token = await KakaoReservationService.instance.getAuthToken();
    final prefs = await SharedPreferences.getInstance();
    final internalToken = prefs.getString('kakao_internal_token');
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };

    String withApi(String b) {
      if (b.endsWith('/api')) return b;
      if (b.endsWith('/api/')) return b.substring(0, b.length - 1);
      return b + '/api';
    }
    String stripApiBase(String b) {
      String u = b;
      if (u.endsWith('/api/')) return u.substring(0, u.length - 5);
      if (u.endsWith('/api')) return u.substring(0, u.length - 4);
      return u;
    }

    final data = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final s in DataManager.instance.students) {
      final sid = s.student.id;
      if (seen.contains(sid)) continue;
      seen.add(sid);
      final String? parentPhone = s.student.parentPhoneNumber ?? s.basicInfo.parentPhoneNumber;
      String parentDigits = '';
      if (parentPhone != null && parentPhone.trim().isNotEmpty) {
        parentDigits = parentPhone.replaceAll(RegExp(r'[^0-9]'), '');
      }
      data.add({
        'studentId': sid,
        'name': s.student.name,
        'parentPhoneDigits': parentDigits,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      });
    }
    try {
      // 1) 내부 토큰 우선 시도
      if (internalToken != null && internalToken.isNotEmpty) {
        final baseNoApi = stripApiBase(baseUrl);
        final internalUri = Uri.parse('$baseNoApi/internal/sync/students');
        final internalHeaders = <String, String>{
          'Content-Type': 'application/json',
          'X-Internal-Token': internalToken,
        };
        // ignore: avoid_print
        print('[SYNC][students][POST] url=$internalUri payloadCount=${data.length} token=internal');
        final res = await http
            .post(internalUri, headers: internalHeaders, body: jsonEncode({'data': data}))
            .timeout(const Duration(seconds: 12));
        // ignore: avoid_print
        print('[SYNC][students][RESP] status=${res.statusCode} len=${res.body.length}');
        if (res.statusCode >= 200 && res.statusCode < 300) {
          return true;
        }
      }

      // 2) 퍼블릭 경로로 폴백 (Bearer)
      final uri = Uri.parse('${withApi(baseUrl)}/sync/students');
      // ignore: avoid_print
      print('[SYNC][students][POST] url=$uri payloadCount=${data.length} token=bearer:${token != null && token.isNotEmpty}');
      final res = await http
          .post(uri, headers: headers, body: jsonEncode({'data': data}))
          .timeout(const Duration(seconds: 12));
      // ignore: avoid_print
      print('[SYNC][students][RESP] status=${res.statusCode} len=${res.body.length}');
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      // ignore: avoid_print
      print('[SYNC][students][ERROR] request failed');
      return false;
    }
  }

  Future<bool> _syncAttendance({required int days}) async {
    final baseUrl = await KakaoReservationService.instance.getBaseUrl();
    if (baseUrl == null || baseUrl.isEmpty) return false;
    final prefs = await SharedPreferences.getInstance();
    final internalToken = prefs.getString('kakao_internal_token');
    final bearerToken = await KakaoReservationService.instance.getAuthToken();
    final String reqId = const Uuid().v4();

    final now = DateTime.now();
    final from = now.subtract(Duration(days: days));
    String withApi(String b) {
      if (b.endsWith('/api')) return b;
      if (b.endsWith('/api/')) return b.substring(0, b.length - 1);
      return b + '/api';
    }

    // 내부 토큰이 있으면 B 형식(items/records)을 우선 시도하되, 실패 시 즉시 폴백을 재시도한다.
    bool attemptedInternal = false;
    bool internalOk = false;
    if (internalToken != null && internalToken.isNotEmpty) {
      String stripApiBase(String b) {
        String u = b;
        if (u.endsWith('/api/')) return u.substring(0, u.length - 5);
        if (u.endsWith('/api')) return u.substring(0, u.length - 4);
        return u;
      }
      final baseNoApi = stripApiBase(baseUrl);
      final Map<String, List<Map<String, dynamic>>> byStudent = <String, List<Map<String, dynamic>>>{};
      int totalRecords = 0;
      for (final r in DataManager.instance.attendanceRecords) {
        if (r.classDateTime.isBefore(DateTime(from.year, from.month, from.day))) continue;
        final String date = _fmtYmd(r.classDateTime);
        final String status = r.isPresent ? '출석' : '결석';
        final String? arrivedAt = r.arrivalTime != null ? _fmtHm(r.arrivalTime!) : null;
        final String? leftAt = r.departureTime != null ? _fmtHm(r.departureTime!) : null;
        final String updatedIso = r.updatedAt.toIso8601String();
        (byStudent[r.studentId] ??= <Map<String, dynamic>>[]).add({
          'date': date,
          'status': status,
          if (arrivedAt != null) 'arrivedAt': arrivedAt,
          if (leftAt != null) 'leftAt': leftAt,
          'updatedAt': updatedIso,
          // 추가: 내부 동기화에도 수업 시간과 ISO 등/하원 시간을 함께 전달하여
          // 서버가 지각/수업중 계산과 주간 응답에 반영할 수 있도록 한다 (하위호환 유지)
          'classStart': r.classDateTime.toUtc().toIso8601String(),
          'classEnd': r.classEndTime.toUtc().toIso8601String(),
          if (r.arrivalTime != null) 'arrival': r.arrivalTime!.toUtc().toIso8601String(),
          if (r.departureTime != null) 'departure': r.departureTime!.toUtc().toIso8601String(),
        });
        totalRecords += 1;
      }
      // 디버그 로그: 전송 예정 건수
      // ignore: avoid_print
      print('[SYNC][attendance][batch] students=${byStudent.length} records=$totalRecords days=$days token=${internalToken.isNotEmpty}');
      if (byStudent.isEmpty) return true; // 전송할 데이터 없음은 성공으로 간주
      final payload = {
        'items': byStudent.entries
            .map((e) => {
                  'studentId': e.key,
                  'records': e.value,
                })
            .toList(),
      };
      final headers = <String, String>{
        'Content-Type': 'application/json',
        'X-Internal-Token': internalToken,
      };
      try {
        attemptedInternal = true;
        // 내부 엔드포인트는 /internal/* (prefix에 /api 없음)
        final uri = Uri.parse('$baseNoApi/internal/sync/attendance');
        // ignore: avoid_print
        print('[SYNC][attendance][POST] url=$uri students=${byStudent.length} records=$totalRecords token=internal reqId=$reqId');
        final res = await http
            .post(uri, headers: {...headers, 'X-Client-Request-Id': reqId}, body: jsonEncode(payload))
            .timeout(const Duration(seconds: 12));
        // ignore: avoid_print
        print('[SYNC][attendance][RESP] status=${res.statusCode} len=${res.body.length} reqId=$reqId');
        internalOk = res.statusCode >= 200 && res.statusCode < 300;
      } catch (e) {
        // ignore: avoid_print
        print('[SYNC][attendance][ERROR][internal] $e reqId=$reqId');
        internalOk = false;
      }
    }

    // 내부 실패 시 또는 내부 토큰이 없는 경우: 폴백 A 형식으로 /api/sync/attendance 재시도
    if (attemptedInternal && internalOk) {
      return true;
    }

    // 폴백: 기존 A 형식으로 /sync/attendance (인증 없음 또는 Bearer)
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (bearerToken != null && bearerToken.isNotEmpty) 'Authorization': 'Bearer $bearerToken',
      'X-Client-Request-Id': reqId,
    };
    final data = <Map<String, dynamic>>[];
    for (final r in DataManager.instance.attendanceRecords) {
      if (r.classDateTime.isBefore(DateTime(from.year, from.month, from.day))) continue;
      final id = r.id ?? '${r.studentId}-${r.classDateTime.toIso8601String()}';
      data.add({
        'id': id,
        'studentId': r.studentId,
        'className': r.className,
        'classStart': r.classDateTime.toUtc().toIso8601String(),
        'classEnd': r.classEndTime.toUtc().toIso8601String(),
        'arrival': r.arrivalTime?.toUtc().toIso8601String(),
        'departure': r.departureTime?.toUtc().toIso8601String(),
        'updatedAt': r.updatedAt.toUtc().toIso8601String(),
      });
    }
    if (data.isEmpty) return true;
    try {
      final uri = Uri.parse('${withApi(baseUrl)}/sync/attendance');
      // ignore: avoid_print
      print('[SYNC][attendance][POST][fallback] url=$uri records=${data.length} reqId=$reqId');
      final res = await http
          .post(uri, headers: headers, body: jsonEncode({'data': data}))
          .timeout(const Duration(seconds: 12));
      // ignore: avoid_print
      print('[SYNC][attendance][RESP][fallback] status=${res.statusCode} len=${res.body.length} reqId=$reqId');
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  // ===================== Incremental attendance sync (queue) =====================
  // Queue of pending attendance records, keyed by studentId|classDateTime ISO minute
  final Map<String, Map<String, dynamic>> _pendingAttendance = <String, Map<String, dynamic>>{};
  Timer? _flushTimer;
  bool _isFlushing = false;

  /// Enqueue a single attendance record for incremental sync.
  /// Merges by (studentId, classDateTime minute) with latest updatedAt winning.
  Future<void> enqueueAttendanceRecord(AttendanceRecord record) async {
    try {
      final key = _pendingKey(record);
      final payload = _buildAttendancePayload(record);
      final prev = _pendingAttendance[key];
      if (prev == null) {
        _pendingAttendance[key] = payload;
      } else {
        // Merge: latest updatedAt wins for status/arrival/departure
        final prevUpdated = DateTime.tryParse((prev['updatedAt'] as String?) ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
        final currUpdated = record.updatedAt;
        if (currUpdated.isAfter(prevUpdated)) {
          _pendingAttendance[key] = payload;
        } else {
          // Keep earlier arrival (earliest) and later departure (latest) if present
          final aPrev = prev['arrival'] as String?;
          final aCurr = payload['arrival'] as String?;
          if (aPrev == null || (aCurr != null && aCurr.compareTo(aPrev) < 0)) {
            prev['arrival'] = aCurr;
          }
          final dPrev = prev['departure'] as String?;
          final dCurr = payload['departure'] as String?;
          if (dPrev == null || (dCurr != null && dCurr.compareTo(dPrev) > 0)) {
            prev['departure'] = dCurr;
          }
          _pendingAttendance[key] = prev;
        }
      }
    } catch (_) {}

    // Debounce flush (400ms)
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(milliseconds: 400), _flushPendingAttendance);
  }

  String _pendingKey(AttendanceRecord r) {
    final dt = DateTime(r.classDateTime.year, r.classDateTime.month, r.classDateTime.day, r.classDateTime.hour, r.classDateTime.minute);
    return '${r.studentId}|${dt.toIso8601String()}';
  }

  Map<String, dynamic> _buildAttendancePayload(AttendanceRecord r) {
    return {
      // keep same shape as _syncAttendance() payload items
      'id': r.id ?? '${r.studentId}-${r.classDateTime.toIso8601String()}',
      'studentId': r.studentId,
      'className': r.className,
      'classStart': r.classDateTime.toUtc().toIso8601String(),
      'classEnd': r.classEndTime.toUtc().toIso8601String(),
      'arrival': r.arrivalTime?.toUtc().toIso8601String(),
      'departure': r.departureTime?.toUtc().toIso8601String(),
      'updatedAt': r.updatedAt.toUtc().toIso8601String(),
      'isPresent': r.isPresent,
    };
  }

  Future<void> _flushPendingAttendance() async {
    if (_isFlushing || _pendingAttendance.isEmpty) return;
    _isFlushing = true;
    try {
      final baseUrl = await KakaoReservationService.instance.getBaseUrl();
      if (baseUrl == null || baseUrl.isEmpty) return;
      // 내부 동기화 토큰 우선 사용(없으면 기존 토큰 fallback)
      final prefs = await SharedPreferences.getInstance();
      final internalToken = prefs.getString('kakao_internal_token');
      final bearerToken = await KakaoReservationService.instance.getAuthToken();
      final headers = <String, String>{
        'Content-Type': 'application/json',
        if (internalToken != null && internalToken.isNotEmpty)
          'X-Internal-Token': internalToken
        else if (bearerToken != null && bearerToken.isNotEmpty)
          'Authorization': 'Bearer $bearerToken',
      };
      String withApi(String b) {
        if (b.endsWith('/api')) return b;
        if (b.endsWith('/api/')) return b.substring(0, b.length - 1);
        return b + '/api';
      }

      // snapshot and clear first to avoid losing new events
      final pending = _pendingAttendance.values.toList();
      _pendingAttendance.clear();

      // 서버 스펙(B 형식): items:[{ studentId, records:[{date,status,arrivedAt,leftAt,updatedAt,idempotencyKey?}] }]
      final Map<String, List<Map<String, dynamic>>> byStudent = <String, List<Map<String, dynamic>>>{};
      for (final m in pending) {
        final sid = (m['studentId'] as String?) ?? '';
        if (sid.isEmpty) continue;
        final classStartIso = m['classStart'] as String?; // 과거 포맷 호환
        final classEndIso = m['classEnd'] as String?;
        final DateTime? classStart = classStartIso != null ? DateTime.tryParse(classStartIso)?.toLocal() : null;
        final DateTime? classEnd = classEndIso != null ? DateTime.tryParse(classEndIso)?.toLocal() : null;
        final DateTime? arrivalDt = (m['arrival'] as String?) != null ? DateTime.tryParse(m['arrival'] as String)?.toLocal() : null;
        final DateTime? departureDt = (m['departure'] as String?) != null ? DateTime.tryParse(m['departure'] as String)?.toLocal() : null;
        final DateTime? updated = (m['updatedAt'] as String?) != null ? DateTime.tryParse(m['updatedAt'] as String)?.toLocal() : null;
        // date(YYYY-MM-DD) 계산: classStart가 있으면 그것으로, 없으면 arrival/updated 우선
        final DateTime anchor = classStart ?? arrivalDt ?? updated ?? DateTime.now();
        final String date = _fmtYmd(anchor);
        final String? arrivedAt = arrivalDt != null ? _fmtHm(arrivalDt) : null;
        final String? leftAt = departureDt != null ? _fmtHm(departureDt) : null;
        final String updatedIso = (updated ?? DateTime.now()).toIso8601String();
        final bool isPresent = (m['isPresent'] as bool?) ?? true;
        final String status = isPresent ? '출석' : '결석';
        (byStudent[sid] ??= <Map<String, dynamic>>[]).add({
          'date': date,
          'status': status,
          if (arrivedAt != null) 'arrivedAt': arrivedAt,
          if (leftAt != null) 'leftAt': leftAt,
          'updatedAt': updatedIso,
          // 추가: 내부 동기화에도 수업 시작/종료 및 ISO 등/하원 포함
          if (classStart != null) 'classStart': classStart.toUtc().toIso8601String(),
          if (classEnd != null) 'classEnd': classEnd.toUtc().toIso8601String(),
          if (arrivalDt != null) 'arrival': arrivalDt.toUtc().toIso8601String(),
          if (departureDt != null) 'departure': departureDt.toUtc().toIso8601String(),
        });
      }

      final body = {
        'items': byStudent.entries
            .map((e) => {
                  'studentId': e.key,
                  'records': e.value,
                })
            .toList(),
      };

      final bool useInternal = internalToken != null && internalToken.isNotEmpty;
      String stripApiBase(String b) {
        String u = b;
        if (u.endsWith('/api/')) return u.substring(0, u.length - 5);
        if (u.endsWith('/api')) return u.substring(0, u.length - 4);
        return u;
      }
      final baseNoApi = stripApiBase(baseUrl);
      final String reqId = const Uuid().v4();
      Uri uri = useInternal
          ? Uri.parse('$baseNoApi/internal/sync/attendance')
          : Uri.parse('${withApi(baseUrl)}/sync/attendance');
      try {
        // ignore: avoid_print
        final total = byStudent.values.fold<int>(0, (acc, v) => acc + v.length);
        print('[SYNC][attendance][flush] url=$uri students=${byStudent.length} records=$total reqId=$reqId');
        var res = await http
            .post(uri, headers: {...headers, 'X-Client-Request-Id': reqId}, body: jsonEncode(body))
            .timeout(const Duration(seconds: 8));
        // 내부 경로 사용 중 실패하면 폴백으로 재시도
        if (useInternal && !(res.statusCode >= 200 && res.statusCode < 300)) {
          uri = Uri.parse('${withApi(baseUrl)}/sync/attendance');
          // ignore: avoid_print
          print('[SYNC][attendance][flush][fallback] url=$uri (retry public) reqId=$reqId');
          final fallbackHeaders = <String, String>{
            'Content-Type': 'application/json',
            if ((await KakaoReservationService.instance.getAuthToken()) != null)
              'Authorization': 'Bearer ${await KakaoReservationService.instance.getAuthToken()}',
            'X-Client-Request-Id': reqId,
          };
          res = await http
              .post(uri, headers: fallbackHeaders, body: jsonEncode(body))
              .timeout(const Duration(seconds: 8));
        }
        // ignore: avoid_print
        print('[SYNC][attendance][flush][resp] status=${res.statusCode} len=${res.body.length} reqId=$reqId');
      } catch (_) {
        // if failed, re-enqueue to avoid data loss
        for (final m in pending) {
          final key = '${m['studentId']}|${m['classStart']}';
          _pendingAttendance[key] = m;
        }
      }
    } finally {
      _isFlushing = false;
    }
  }

  String _fmtYmd(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  String _fmtHm(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}



