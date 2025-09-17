import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'data_manager.dart';
import '../models/parent_link.dart';

class ParentLinkService {
  ParentLinkService._internal();
  static final ParentLinkService instance = ParentLinkService._internal();

  final ValueNotifier<List<ParentLink>> linksNotifier = ValueNotifier<List<ParentLink>>(<ParentLink>[]);

  Future<String?> _getBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('kakao_api_base_url');
    if (url == null || url.trim().isEmpty) return null;
    return url.trim().replaceAll(RegExp(r'/+\/?$'), '');
  }

  Future<String?> _getToken() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('kakao_api_token');
    if (token == null || token.trim().isEmpty) return null;
    return token.trim();
  }

  Future<void> fetchRecentLinks() async {
    final base = await _getBaseUrl();
    if (base == null) return;
    final token = await _getToken();
    String _withApi(String b) {
      // base가 이미 /api로 끝나면 그대로 사용, 아니면 /api를 붙인다
      if (b.endsWith('/api')) return b;
      if (b.endsWith('/api/')) return b.substring(0, b.length - 1);
      return b + '/api';
    }
    final uri = Uri.parse('${_withApi(base)}/parent/status');

    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
    try {
      final res = await http.get(uri, headers: headers).timeout(const Duration(seconds: 8));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final body = json.decode(res.body);
        List<dynamic> rawList;
        if (body is List) {
          rawList = body;
        } else if (body is Map<String, dynamic>) {
          rawList = (body['data'] ?? body['links'] ?? body['items'] ?? body['results'] ?? body['list']) as List<dynamic>? ?? <dynamic>[];
        } else {
          rawList = <dynamic>[];
        }
        var items = rawList.whereType<Map<String, dynamic>>().map((e) => ParentLink.fromJson(e)).toList();

        // DB 학생 목록과 부모 연락처로 매칭하여 이름 보강
        try {
          final students = DataManager.instance.students;
          String digits(String? s) => (s ?? '').replaceAll(RegExp(r'[^0-9]'), '');
          final phoneToStudentName = <String, String>{};
          final phoneToStudentId = <String, String>{};
          for (final si in students) {
            final p = digits(si.student.parentPhoneNumber ?? si.basicInfo.parentPhoneNumber);
            if (p.isNotEmpty) {
              phoneToStudentName[p] = si.student.name;
              phoneToStudentId[p] = si.student.id;
            }
          }

          final toPush = <ParentLink>[];
          items = items.map((p) {
            final d = digits(p.phone);
            final name = phoneToStudentName[d];
            if (name == null || name.isEmpty) return p;
            final updated = p.copyWith(matchedStudentName: name);
            // 서버에 아직 matchedStudentId가 없다면 업서트 예약
            if ((p.matchedStudentId == null || p.matchedStudentId!.isEmpty) && d.isNotEmpty) {
              toPush.add(updated);
            }
            return updated;
          }).toList();

          // 백그라운드로 서버에 매칭 결과 업로드
          for (final link in toPush) {
            final phone = digits(link.phone);
            final sid = phoneToStudentId[phone];
            if (sid == null || sid.isEmpty) {
              debugPrint('[ParentLinkService] skip pushMatch: no local student for phone=$phone');
              continue; // 잘못된 매핑을 방지하기 위해 폴백 금지
            }
            _pushMatch(
              kakaoUserId: link.kakaoUserId,
              phoneDigits: phone,
              studentId: sid,
              studentName: link.matchedStudentName,
            );
          }
        } catch (e) {
          debugPrint('[ParentLinkService] local match failed: $e');
        }

        linksNotifier.value = List.unmodifiable(items);
      } else {
        debugPrint('[ParentLinkService] fetchRecentLinks status=${res.statusCode} body=${res.body}');
      }
    } catch (e) {
      debugPrint('[ParentLinkService] fetchRecentLinks error: $e');
    }
  }

  Future<bool> deleteLink(ParentLink link) async {
    final base = await _getBaseUrl();
    if (base == null) return false;
    final token = await _getToken();
    String withApi(String b) {
      if (b.endsWith('/api')) return b;
      if (b.endsWith('/api/')) return b.substring(0, b.length - 1);
      return b + '/api';
    }
    Uri uri;
    if ((link.id).isNotEmpty) {
      uri = Uri.parse('${withApi(base)}/parent/link/${link.id}');
    } else {
      final qp = <String, String>{};
      if ((link.phone ?? '').isNotEmpty) qp['phone'] = link.phone!;
      if ((link.kakaoUserId ?? '').isNotEmpty) qp['userId'] = link.kakaoUserId!;
      uri = Uri.parse('${withApi(base)}/parent/link').replace(queryParameters: qp.isEmpty ? null : qp);
    }
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
    try {
      final res = await http.delete(uri, headers: headers).timeout(const Duration(seconds: 8));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        // 낙관적 업데이트
        final next = List<ParentLink>.from(linksNotifier.value)..removeWhere((p) => p.id == link.id || (p.phone == link.phone && p.kakaoUserId == link.kakaoUserId));
        linksNotifier.value = List.unmodifiable(next);
        return true;
      }
    } catch (e) {
      debugPrint('[ParentLinkService] deleteLink error: $e');
    }
    return false;
  }

  Future<void> _pushMatch({
    String? kakaoUserId,
    required String phoneDigits,
    required String studentId,
    String? studentName,
  }) async {
    try {
      if (phoneDigits.isEmpty || studentId.isEmpty) return;
      final base = await _getBaseUrl();
      if (base == null) return;
      final token = await _getToken();
      String withApi(String b) {
        if (b.endsWith('/api')) return b;
        if (b.endsWith('/api/')) return b.substring(0, b.length - 1);
        return b + '/api';
      }
      final uri = Uri.parse('${withApi(base)}/parent/link/match');
      final headers = <String, String>{
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };
      final body = jsonEncode({
        'userId': kakaoUserId,
        'phone': phoneDigits,
        'studentId': studentId,
        if (studentName != null) 'studentName': studentName,
      });
      await http.post(uri, headers: headers, body: body).timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('[ParentLinkService] _pushMatch error: $e');
    }
  }
}



