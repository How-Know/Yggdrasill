/// 학생앱 기본 설정.
///
/// 학습앱(apps/yggdrasill)과 같은 Supabase 프로젝트를 사용한다.
/// --dart-define(SUPABASE_URL / SUPABASE_ANON_KEY)로 재정의 가능.
library;

const String kDefaultSupabaseUrl = 'https://jkanrdxaidumlvpntudy.supabase.co';
const String kDefaultSupabaseAnonKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImprYW5yZHhhaWR1bWx2cG50dWR5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTgxODE4MjYsImV4cCI6MjA3Mzc1NzgyNn0.fTH_1bV8topfhaw2o-xLY8KvX_eRlomruqMyESJogPg';

String resolveSupabaseUrl() {
  const fromDefine = String.fromEnvironment('SUPABASE_URL', defaultValue: '');
  return fromDefine.isNotEmpty ? fromDefine : kDefaultSupabaseUrl;
}

String resolveSupabaseAnonKey() {
  const fromDefine =
      String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: '');
  return fromDefine.isNotEmpty ? fromDefine : kDefaultSupabaseAnonKey;
}

/// 학생 아이디 → 내부 이메일 변환 도메인 (student_signup Edge Function과 동일).
const String kStudentEmailDomain = 'student.yggdrasill.app';
