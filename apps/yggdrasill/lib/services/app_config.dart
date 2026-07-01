// App-wide default configuration for production
// 안전상 Supabase anon key는 공개 가능 범주(퍼블릭 롤)이며, 서버 보안은 RLS/정책으로 보호됩니다.

const String kDefaultSupabaseUrl = 'https://jkanrdxaidumlvpntudy.supabase.co';
const String kDefaultSupabaseAnonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImprYW5yZHhhaWR1bWx2cG50dWR5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTgxODE4MjYsImV4cCI6MjA3Mzc1NzgyNn0.fTH_1bV8topfhaw2o-xLY8KvX_eRlomruqMyESJogPg';

/// 런타임에 실제로 사용된 Supabase 접속 정보(dart-define/env/기본값 중 해석된 값).
/// main.dart의 Supabase.initialize 직후 채워진다. Watch 토큰 릴레이 등에서 사용.
String gResolvedSupabaseUrl = kDefaultSupabaseUrl;
String gResolvedSupabaseAnonKey = kDefaultSupabaseAnonKey;


