import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import '../services/data_manager.dart';
import 'kakao_reservation_service.dart';

class SyncService {
  SyncService._internal();
  static final SyncService instance = SyncService._internal();

  static const String _initialFlagKey = 'initial_sync_done_v1';

  Future<void> runInitialSyncIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    final done = prefs.getBool(_initialFlagKey) ?? false;
    if (done) return;
    await _syncStudents();
    await _syncAttendance(days: 14);
    await prefs.setBool(_initialFlagKey, true);
  }

  Future<void> manualSync() async {
    await _syncStudents();
    await _syncAttendance(days: 14);
  }

  Future<void> _syncStudents() async {
    final baseUrl = await KakaoReservationService.instance.getBaseUrl();
    if (baseUrl == null || baseUrl.isEmpty) return;
    final token = await KakaoReservationService.instance.getAuthToken();
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };

    final items = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final s in DataManager.instance.students) {
      final sid = s.student.id;
      if (seen.contains(sid)) continue;
      seen.add(sid);
      final String? parentPhone = s.student.parentPhoneNumber ?? s.basicInfo.parentPhoneNumber;
      final List<String> parentPhones = [];
      if (parentPhone != null && parentPhone.trim().isNotEmpty) {
        final digits = parentPhone.replaceAll(RegExp(r'[^0-9]'), '');
        if (digits.isNotEmpty) parentPhones.add(digits);
      }
      items.add({
        'studentId': sid,
        'studentName': s.student.name,
        'parentPhones': parentPhones,
      });
    }
    try {
      final uri = Uri.parse('$baseUrl/sync/students');
      await http
          .post(uri, headers: headers, body: jsonEncode({'items': items}))
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  Future<void> _syncAttendance({required int days}) async {
    final baseUrl = await KakaoReservationService.instance.getBaseUrl();
    if (baseUrl == null || baseUrl.isEmpty) return;
    final token = await KakaoReservationService.instance.getAuthToken();
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };

    final now = DateTime.now();
    final from = now.subtract(Duration(days: days));
    final df = DateFormat('yyyy-MM-dd');
    final items = <Map<String, dynamic>>[];
    for (final r in DataManager.instance.attendanceRecords) {
      if (r.classDateTime.isBefore(DateTime(from.year, from.month, from.day))) continue;
      final classDate = df.format(r.classDateTime);
      items.add({
        'studentId': r.studentId,
        'classDate': classDate,
        'arrivalTime': r.arrivalTime?.toIso8601String(),
        'departureTime': r.departureTime?.toIso8601String(),
      });
    }
    try {
      final uri = Uri.parse('$baseUrl/sync/attendance');
      await http
          .post(uri, headers: headers, body: jsonEncode({'items': items}))
          .timeout(const Duration(seconds: 12));
    } catch (_) {}
  }
}



