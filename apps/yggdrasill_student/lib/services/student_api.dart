import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_config.dart';

/// 과제 그룹 (m5_list_homework_groups와 동일 형태).
class HomeworkGroup {
  HomeworkGroup({
    required this.groupId,
    required this.title,
    required this.orderIndex,
    required this.phase,
    required this.accumulated,
    required this.cycleElapsed,
    required this.checkCount,
    required this.totalCount,
    required this.color,
    required this.pageSummary,
    required this.runStart,
    required this.content,
    required this.type,
    required this.timeLimitMinutes,
    required this.waitTitle,
    required this.children,
    this.isTest = false,
    this.isNaesin = false,
    this.pendingComplete = false,
    this.isHomeworkOnly = false,
  });

  final String groupId;
  final String title;
  final int orderIndex;
  final int phase;
  final int accumulated; // 누적(초)
  final int cycleElapsed; // 현재 사이클 경과(초)
  final int checkCount;
  final int totalCount;
  final int color;
  final String pageSummary;
  final DateTime? runStart;
  final String content;
  final String type;
  final int? timeLimitMinutes;
  final String waitTitle;
  final List<HomeworkChild> children;
  bool isTest;
  bool isNaesin;
  bool pendingComplete;
  final bool isHomeworkOnly;

  /// 목록을 불러온 시각. 수행 중 경과시간 표시에 사용.
  final DateTime fetchedAt = DateTime.now();

  bool get running => phase == 2 && runStart != null;

  /// 지금 시점 기준 사이클 경과(초).
  int liveCycleElapsed() {
    if (!running) return cycleElapsed;
    final extra = DateTime.now().difference(fetchedAt).inSeconds;
    return cycleElapsed + (extra > 0 ? extra : 0);
  }

  static HomeworkGroup fromRow(Map<String, dynamic> row,
      {bool homeworkOnly = false}) {
    List<HomeworkChild> children = const [];
    final rawChildren = row['children'];
    if (rawChildren is List) {
      children = rawChildren
          .whereType<Map<String, dynamic>>()
          .map(HomeworkChild.fromRow)
          .toList(growable: false);
    }
    return HomeworkGroup(
      groupId: row['group_id'] as String,
      title: (row['group_title'] as String?) ?? '',
      orderIndex: (row['order_index'] as num?)?.toInt() ?? 0,
      phase: (row['phase'] as num?)?.toInt() ?? 1,
      accumulated: (row['accumulated'] as num?)?.toInt() ?? 0,
      cycleElapsed: (row['cycle_elapsed'] as num?)?.toInt() ?? 0,
      checkCount: (row['check_count'] as num?)?.toInt() ?? 0,
      totalCount: (row['total_count'] as num?)?.toInt() ?? 0,
      color: (row['color'] as num?)?.toInt() ?? 0,
      pageSummary: (row['page_summary'] as String?) ?? '',
      runStart: row['run_start'] != null
          ? DateTime.tryParse(row['run_start'] as String)
          : null,
      content: (row['content'] as String?) ?? '',
      type: (row['type'] as String?) ?? '',
      timeLimitMinutes: (row['time_limit_minutes'] as num?)?.toInt(),
      waitTitle: (row['m5_wait_title'] as String?) ?? '',
      children: children,
      isHomeworkOnly: homeworkOnly,
    );
  }
}

class HomeworkChild {
  const HomeworkChild({
    required this.title,
    required this.page,
    required this.count,
    required this.memo,
    required this.phase,
  });

  final String title;
  final String page;
  final String count;
  final String memo;
  final int phase;

  static HomeworkChild fromRow(Map<String, dynamic> row) {
    return HomeworkChild(
      title: (row['title'] as String?) ?? '',
      page: (row['page'] as String?) ?? '',
      count: '${row['count'] ?? ''}',
      memo: (row['memo'] as String?) ?? '',
      phase: (row['phase'] as num?)?.toInt() ?? 1,
    );
  }
}

class StudentInfo {
  const StudentInfo({
    required this.name,
    required this.school,
    required this.grade,
    required this.startHour,
    required this.startMinute,
    required this.duration,
  });

  final String name;
  final String school;
  final int? grade;
  final int? startHour;
  final int? startMinute;
  final int? duration;
}

class AcademyBranding {
  const AcademyBranding({
    required this.name,
    this.logoUrl = '',
  });

  final String name;
  final String logoUrl;
}

class QuickLoginStudent {
  const QuickLoginStudent({
    required this.id,
    required this.name,
    required this.school,
    required this.grade,
    required this.startHour,
    required this.startMinute,
  });

  final String id;
  final String name;
  final String school;
  final int? grade;
  final int? startHour;
  final int? startMinute;

  static QuickLoginStudent fromRow(Map<String, dynamic> row) {
    return QuickLoginStudent(
      id: '${row['student_id'] ?? ''}',
      name: '${row['name'] ?? ''}',
      school: '${row['school'] ?? ''}',
      grade: (row['grade'] as num?)?.toInt(),
      startHour: (row['start_hour'] as num?)?.toInt(),
      startMinute: (row['start_minute'] as num?)?.toInt(),
    );
  }
}

class QuickLoginRoster {
  const QuickLoginRoster({
    required this.students,
    required this.networkProtected,
  });

  final List<QuickLoginStudent> students;
  final bool networkProtected;
}

class TodayAttendance {
  const TodayAttendance({this.arrival, this.departure, this.classDateTime});

  final DateTime? arrival;
  final DateTime? departure;
  final DateTime? classDateTime;
}

/// Supabase 직접 통신 API. 모든 호출은 로그인된 학생 세션 기준(RPC가 본인 검증).
class StudentApi {
  StudentApi._();
  static final StudentApi instance = StudentApi._();

  SupabaseClient get _client => Supabase.instance.client;

  bool get isLoggedIn => _client.auth.currentSession != null;

  // ---------------------------------------------------------------- 인증

  /// 학생 아이디 + 비밀번호 로그인.
  Future<void> signIn({required String username, required String password}) {
    final email = '${username.trim().toLowerCase()}@$kStudentEmailDomain';
    return _client.auth
        .signInWithPassword(email: email, password: password)
        .then((_) {});
  }

  /// 가입코드 기반 회원가입 (student_signup Edge Function 호출) 후 자동 로그인.
  Future<void> signUp({
    required String code,
    required String username,
    required String password,
  }) async {
    final uri =
        Uri.parse('${resolveSupabaseUrl()}/functions/v1/student_signup');
    final res = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${resolveSupabaseAnonKey()}',
        'apikey': resolveSupabaseAnonKey(),
      },
      body: jsonEncode({
        'code': code.trim(),
        'username': username.trim().toLowerCase(),
        'password': password,
      }),
    );
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (body['ok'] != true) {
      throw StudentApiException(_signupErrorMessage('${body['error']}'));
    }
    await signIn(username: username, password: password);
  }

  Future<void> signOut() => _client.auth.signOut();

  Future<Map<String, dynamic>> _quickLoginRequest(
    Map<String, dynamic> body,
  ) async {
    final uri =
        Uri.parse('${resolveSupabaseUrl()}/functions/v1/student_pin_login');
    final response = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${resolveSupabaseAnonKey()}',
        'apikey': resolveSupabaseAnonKey(),
      },
      body: jsonEncode(body),
    );
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw StudentApiException('빠른 로그인 서버 응답을 확인할 수 없어요.');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<QuickLoginRoster> listQuickLoginStudents() async {
    final result = await _quickLoginRequest(const {'action': 'list'});
    if (result['ok'] != true) {
      throw StudentApiException(_quickLoginErrorMessage('${result['error']}'));
    }
    final students = (result['students'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((row) => QuickLoginStudent.fromRow(
              Map<String, dynamic>.from(row),
            ))
        .toList(growable: false);
    return QuickLoginRoster(
      students: students,
      networkProtected: result['network_protected'] == true,
    );
  }

  Future<void> signInWithPin({
    required String studentId,
    required String pin,
  }) async {
    final result = await _quickLoginRequest({
      'action': 'login',
      'student_id': studentId,
      'pin': pin,
    });
    if (result['ok'] != true) {
      throw StudentApiException(
          _quickLoginErrorMessage('${result['error']}', result: result));
    }
    final tokenHash = '${result['token_hash'] ?? ''}'.trim();
    if (tokenHash.isEmpty) {
      throw StudentApiException('로그인 세션을 만들지 못했어요.');
    }
    await _client.auth.verifyOTP(
      tokenHash: tokenHash,
      type: OtpType.magiclink,
    );
  }

  static String _quickLoginErrorMessage(
    String code, {
    Map<String, dynamic>? result,
  }) {
    switch (code) {
      case 'network_not_allowed':
        return '학원 Wi-Fi에 연결된 기기에서만 사용할 수 있어요.';
      case 'pin_invalid':
        return 'PIN이 맞지 않아요. ${result?['attempts_left'] ?? 0}번 더 입력할 수 있어요.';
      case 'locked':
        final seconds = (result?['locked_seconds'] as num?)?.toInt() ?? 300;
        return '입력 횟수를 초과했어요. ${((seconds + 59) ~/ 60)}분 뒤 다시 시도해 주세요.';
      case 'not_eligible':
        return '지금은 이 학생으로 빠른 로그인할 수 없어요.';
      default:
        return '빠른 로그인에 실패했어요. ($code)';
    }
  }

  static String _signupErrorMessage(String code) {
    switch (code) {
      case 'code_not_found':
        return '가입코드를 찾을 수 없어요. 다시 확인해 주세요.';
      case 'code_used':
        return '이미 사용된 가입코드예요.';
      case 'code_expired':
        return '만료된 가입코드예요. 선생님께 새로 발급받아 주세요.';
      case 'already_registered':
        return '이미 계정이 만들어진 학생이에요.';
      case 'username_taken':
        return '이미 사용 중인 아이디예요.';
      case 'invalid_username':
        return '아이디는 영문 소문자/숫자 3~20자로 만들어 주세요.';
      case 'weak_password':
        return '비밀번호는 6자 이상이어야 해요.';
      default:
        return '가입에 실패했어요. ($code)';
    }
  }

  // ---------------------------------------------------------------- 조회

  /// 로그인 전에도 표시 가능한 전용 학원 공개 브랜딩.
  Future<AcademyBranding> getPublicAcademyBranding() async {
    final rows =
        await _client.rpc('student_public_academy_branding') as List<dynamic>;
    if (rows.isEmpty) {
      return const AcademyBranding(name: '정현수학교습소');
    }
    final row = Map<String, dynamic>.from(rows.first as Map);
    final bucket = '${row['logo_bucket'] ?? ''}'.trim();
    final path = '${row['logo_path'] ?? ''}'.trim();
    var logoUrl = '${row['logo_url'] ?? ''}'.trim();
    if (bucket.isNotEmpty && path.isNotEmpty) {
      try {
        logoUrl =
            await _client.storage.from(bucket).createSignedUrl(path, 60 * 60);
      } catch (_) {
        // 이전 공개 URL이 있으면 그대로 사용한다.
      }
    }
    return AcademyBranding(
      name: '${row['academy_name'] ?? '정현수학교습소'}'.trim(),
      logoUrl: logoUrl,
    );
  }

  Future<StudentInfo?> getInfo() async {
    final rows = await _client.rpc('student_get_info') as List<dynamic>;
    if (rows.isEmpty) return null;
    final row = rows.first as Map<String, dynamic>;
    return StudentInfo(
      name: (row['name'] as String?) ?? '',
      school: (row['school'] as String?) ?? '',
      grade: (row['grade'] as num?)?.toInt(),
      startHour: (row['start_hour'] as num?)?.toInt(),
      startMinute: (row['start_minute'] as num?)?.toInt(),
      duration: (row['duration'] as num?)?.toInt(),
    );
  }

  /// 과제 그룹 목록 (메인 + 하원숙제 + 플래그 병합).
  Future<List<HomeworkGroup>> listHomeworkGroups() async {
    final results = await Future.wait([
      _client.rpc('student_list_homework_groups_v1'),
      _client.rpc('student_list_homework_only_groups_v1'),
      _client.rpc('student_group_test_naesin_flags'),
      _client.rpc('student_group_pending_complete_flags'),
    ]);

    final main = (results[0] as List<dynamic>)
        .whereType<Map<String, dynamic>>()
        .map((r) => HomeworkGroup.fromRow(r))
        .toList();
    final homeworkOnly = (results[1] as List<dynamic>)
        .whereType<Map<String, dynamic>>()
        .map((r) => HomeworkGroup.fromRow(r, homeworkOnly: true))
        .toList();

    final flags = <String, Map<String, dynamic>>{};
    for (final r in (results[2] as List<dynamic>)) {
      if (r is Map<String, dynamic>) flags[r['group_id'] as String] = r;
    }
    final pending = <String, bool>{};
    for (final r in (results[3] as List<dynamic>)) {
      if (r is Map<String, dynamic>) {
        pending[r['group_id'] as String] =
            (r['pending_complete'] as bool?) ?? false;
      }
    }

    final all = [...main, ...homeworkOnly];
    for (final g in all) {
      final f = flags[g.groupId];
      if (f != null) {
        g.isTest = (f['is_test'] as bool?) ?? false;
        g.isNaesin = (f['is_naesin'] as bool?) ?? false;
      }
      g.pendingComplete = pending[g.groupId] ?? false;
    }
    all.sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
    return all;
  }

  Future<TodayAttendance> todayAttendance() async {
    final rows = await _client.rpc('student_today_attendance') as List<dynamic>;
    if (rows.isEmpty) return const TodayAttendance();
    final row = rows.first as Map<String, dynamic>;
    DateTime? parse(String key) => row[key] != null
        ? DateTime.tryParse(row[key] as String)?.toLocal()
        : null;
    return TodayAttendance(
      arrival: parse('arrival_time'),
      departure: parse('departure_time'),
      classDateTime: parse('class_date_time'),
    );
  }

  // ---------------------------------------------------------------- 기록

  /// 그룹 전환. from_phase: 1(시작)/2/4(확인→대기)/99(제출).
  Future<Map<String, dynamic>> groupTransition({
    required String groupId,
    required int fromPhase,
  }) async {
    final requestId =
        '${DateTime.now().millisecondsSinceEpoch}-$groupId-$fromPhase';
    final result = await _client.rpc('student_group_transition', params: {
      'p_group_id': groupId,
      'p_from_phase': fromPhase,
      'p_request_id': requestId,
    });
    return (result as Map<String, dynamic>?) ?? const {'ok': false};
  }

  Future<void> pauseAll() => _client.rpc('student_pause_all');

  Future<void> raiseQuestion() => _client.rpc('student_raise_question');

  Future<Map<String, dynamic>> createDescriptiveWriting() async {
    final result = await _client.rpc('student_create_descriptive_writing');
    return (result as Map<String, dynamic>?) ?? const {};
  }

  Future<void> recordArrival() => _client.rpc('student_record_arrival');

  Future<void> recordDeparture() => _client.rpc('student_record_departure');
}

class StudentApiException implements Exception {
  StudentApiException(this.message);
  final String message;

  @override
  String toString() => message;
}
