import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/services.dart';
import 'dart:convert';

class AuthService {
  static String _supabaseUrl = '';
  static String _supabaseAnonKey = '';
  static String _adminEmails = '';
  
  static final SupabaseClient supabase = Supabase.instance.client;

  // WebView(성향조사 관리자) 주입용
  static String get supabaseUrl => _supabaseUrl;
  static String get supabaseAnonKey => _supabaseAnonKey;
  
  // 관리자 이메일 목록
  static List<String> getAllowedAdmins() {
    return _adminEmails.split(',').map((s) => s.trim().toLowerCase()).where((s) => s.isNotEmpty).toList();
  }
  
  // Supabase 초기화
  static Future<void> initialize() async {
    // 1. dart-define에서 읽기 시도
    const envUrl = String.fromEnvironment('SUPABASE_URL', defaultValue: '');
    const envKey = String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: '');
    const envEmails = String.fromEnvironment('ADMIN_EMAILS', defaultValue: '');
    
    if (envUrl.isNotEmpty && envKey.isNotEmpty) {
      _supabaseUrl = envUrl;
      _supabaseAnonKey = envKey;
      _adminEmails = envEmails;
    } else {
      // 2. env.local.json에서 읽기
      try {
        final jsonString = await rootBundle.loadString('env.local.json');
        final config = jsonDecode(jsonString) as Map<String, dynamic>;
        _supabaseUrl = config['SUPABASE_URL'] as String? ?? '';
        _supabaseAnonKey = config['SUPABASE_ANON_KEY'] as String? ?? '';
        _adminEmails = config['ADMIN_EMAILS'] as String? ?? '';
      } catch (e) {
        throw Exception('env.local.json 파일을 찾을 수 없거나 파싱할 수 없습니다: $e');
      }
    }
    
    if (_supabaseUrl.isEmpty || _supabaseAnonKey.isEmpty) {
      throw Exception('SUPABASE_URL 또는 SUPABASE_ANON_KEY가 설정되지 않았습니다.');
    }
    
    await Supabase.initialize(
      url: _supabaseUrl,
      anonKey: _supabaseAnonKey,
    );
  }
  
  // 현재 사용자 가져오기
  static User? get currentUser => supabase.auth.currentUser;
  
  // 관리자 권한 확인
  static bool isAdmin() {
    final user = currentUser;
    if (user == null) return false;
    
    final allowed = getAllowedAdmins();
    if (allowed.isEmpty) return true; // 제한 없음
    
    return allowed.contains((user.email ?? '').toLowerCase());
  }
  
  // OTP 전송
  static Future<void> sendOtp(String email) async {
    final allowed = getAllowedAdmins();
    if (allowed.isNotEmpty && !allowed.contains(email.trim().toLowerCase())) {
      throw Exception('허용된 관리자 이메일이 아닙니다.');
    }
    
    await supabase.auth.signInWithOtp(
      email: email.trim(),
      shouldCreateUser: false,
    );
  }
  
  // OTP 확인
  static Future<void> verifyOtp(String email, String code) async {
    await supabase.auth.verifyOTP(
      email: email.trim(),
      token: code.trim(),
      type: OtpType.email,
    );
    
    // 관리자 권한 재확인
    if (!isAdmin()) {
      await signOut();
      throw Exception('관리자 권한이 없는 계정입니다.');
    }
  }
  
  // 로그아웃
  static Future<void> signOut() async {
    await supabase.auth.signOut();
  }
  
  // 인증 상태 스트림
  static Stream<AuthState> get authStateChanges => supabase.auth.onAuthStateChange;
}

