import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// 메모 요약·일정/연락처/이름 추출.
/// AI 호출은 Edge Function `ai_memo_assist`가 한다(OpenAI 키는 서버 비밀값).
/// 꺼져 있거나 실패하면 정규식 처리로 돌아간다.
class AiSummaryService {
  static const String _functionName = 'ai_memo_assist';
  static bool? _serverConfigured;

  static Future<bool> _isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('ai_summary_enabled') ?? false;
  }

  static Future<String?> _invoke(String task, String text,
      {int? maxChars}) async {
    try {
      final res = await Supabase.instance.client.functions.invoke(
        _functionName,
        body: {
          'task': task,
          'text': text,
          if (maxChars != null) 'max_chars': maxChars,
        },
      ).timeout(const Duration(seconds: 20));
      final data = res.data;
      if (data is Map && data['ok'] == true) {
        final value = data['value'];
        if (value is String && value.trim().isNotEmpty) return value.trim();
      }
    } catch (e) {
      print('[AI] $task 실패: $e');
    }
    return null;
  }

  /// 서버에 OpenAI 키가 설정돼 있는지(설정 화면의 AI 토글 활성화용).
  static Future<bool> isServerConfigured({bool refresh = false}) async {
    final cached = _serverConfigured;
    if (!refresh && cached != null) return cached;
    try {
      final res = await Supabase.instance.client.functions
          .invoke(_functionName, body: {'task': 'status'}).timeout(
              const Duration(seconds: 10));
      final data = res.data;
      final configured = data is Map && data['configured'] == true;
      _serverConfigured = configured;
      return configured;
    } catch (e) {
      print('[AI] 서버 상태 확인 실패: $e');
      return false;
    }
  }

  static Future<String> summarize(String text, {int maxChars = 60}) async {
    if (!await _isEnabled()) {
      return toSingleSentence(text, maxChars: maxChars);
    }
    final out = await _invoke('summarize', text, maxChars: maxChars);
    return toSingleSentence(out ?? text, maxChars: maxChars);
  }

  /// 한 문장 요약(시간표 메모용). 실패하면 null을 돌려 호출부가 직접 줄인다.
  static Future<String?> summarizeSentence(String text,
      {int maxChars = 60}) async {
    if (!await _isEnabled()) return null;
    return _invoke('summarize_sentence', text, maxChars: maxChars);
  }

  // ✅ 메모 자동 카테고리 분류(특히 GPT 기반)는 요청에 따라 제거됨.

  static String toSingleSentence(String raw, {int maxChars = 60}) {
    var s = raw.replaceAll('\n', ' ').replaceAll('\r', ' ');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    final endIdx = _firstSentenceEndIndex(s);
    if (endIdx != -1) s = s.substring(0, endIdx + 1);
    if (s.runes.length <= maxChars) return s;
    final clipped = _clipRunes(s, maxChars);
    final clippedEnd = _firstSentenceEndIndex(clipped);
    if (clippedEnd != -1) return clipped.substring(0, clippedEnd + 1);
    return clipped + '…';
  }

  static int _firstSentenceEndIndex(String s) {
    final patterns = ['다.', '요.', '니다.', '함.', '.', '!', '?'];
    int best = -1;
    for (final p in patterns) {
      final idx = s.indexOf(p);
      if (idx != -1) {
        final end = idx + p.length - 1;
        if (best == -1 || end < best) best = end;
      }
    }
    return best;
  }

  static String _clipRunes(String s, int maxChars) {
    final it = s.runes.iterator;
    final buf = StringBuffer();
    int count = 0;
    while (it.moveNext()) {
      buf.writeCharCode(it.current);
      count++;
      if (count >= maxChars) break;
    }
    return buf.toString();
  }
  static Future<DateTime?> extractDateTime(String text) async {
    // 0) 전화번호 제거 및 상대일(오늘/내일/모레/글피) 우선 처리
    String _scrubPhones(String s) => s.replaceAll(RegExp(r'(01[016789])[- .]?(\d{3,4})[- .]?(\d{4})'), ' ');
    final now = DateTime.now();
    final sanitized = _scrubPhones(text);
    bool isAmEarly = RegExp(r"오전").hasMatch(sanitized);
    bool isPmEarly = RegExp(r"오후").hasMatch(sanitized);
    String plainEarly = sanitized.replaceAll('오전', '').replaceAll('오후', '');
    int? dayOffset0;
    if (RegExp(r"오늘").hasMatch(sanitized)) dayOffset0 = 0;
    if (RegExp(r"내일").hasMatch(sanitized)) dayOffset0 = 1;
    if (RegExp(r"모레").hasMatch(sanitized)) dayOffset0 = 2;
    if (RegExp(r"글피").hasMatch(sanitized)) dayOffset0 = 3;
    if (dayOffset0 != null) {
      final reTime0 = RegExp(r"(\d{1,2})(?::(\d{2}))?\s*(?:분|시)?");
      final tm0 = reTime0.firstMatch(plainEarly);
      int h0 = 9;
      int mi0 = 0;
      if (tm0 != null) {
        h0 = int.tryParse(tm0.group(1) ?? '9') ?? 9;
        mi0 = int.tryParse(tm0.group(2) ?? '0') ?? 0;
      }
      // 모호한 시간(오전/오후 키워드 없음)인데 1~11시이면 오후로 해석
      if (!isAmEarly && !isPmEarly && h0 >= 1 && h0 <= 11) h0 += 12;
      if (isPmEarly && h0 >= 1 && h0 <= 11) h0 += 12;
      if (isAmEarly && h0 == 12) h0 = 0;
      final base0 = DateTime(now.year, now.month, now.day).add(Duration(days: dayOffset0));
      return DateTime(base0.year, base0.month, base0.day, h0, mi0);
    }

    // 1) AI 시도 (상대일이 아닌 경우에만)
    if (!await _isEnabled()) {
      return null;
    }
    final aiOut = await _invoke('extract_datetime', sanitized);
    if (aiOut != null) {
      try {
        return DateTime.parse(aiOut);
      } catch (_) {}
    }

    // 2) 정규식 폴백: yyyy-MM-dd HH:mm 또는 M월 d일 등
    // 공통: 오전/오후 감지
    bool isAm = RegExp(r"오전").hasMatch(sanitized);
    bool isPm = RegExp(r"오후").hasMatch(sanitized);
    String plain = sanitized.replaceAll('오전', '').replaceAll('오후', '');

    // 2-1) ISO 혹은 yyyy-MM-dd HH:mm / yyyy/MM/dd HH:mm 등
    final reIso = RegExp(r"(\d{4})[-\/.](\d{1,2})[-\/.](\d{1,2})(?:\s+(\d{1,2})(?::(\d{2}))?)?");
    final m1 = reIso.firstMatch(plain);
    if (m1 != null) {
      final y = int.parse(m1.group(1)!);
      final mo = int.parse(m1.group(2)!);
      final d = int.parse(m1.group(3)!);
      int h = m1.group(4) != null ? int.parse(m1.group(4)!) : 9;
      final mi = m1.group(5) != null ? int.parse(m1.group(5)!) : 0;
      if (isPm && h >= 1 && h <= 11) h += 12;
      if (isAm && h == 12) h = 0;
      return DateTime(y, mo, d, h, mi);
    }

    // 2-1.5) 연도 생략: M/d 또는 M.d 또는 M-d [시:분 옵션]
    final reMd = RegExp(r"\b(\d{1,2})[\/.\-](\d{1,2})(?:\s+(\d{1,2})(?::(\d{2}))?)?\b");
    final mMd = reMd.firstMatch(plain);
    if (mMd != null) {
      final mo = int.parse(mMd.group(1)!);
      final d = int.parse(mMd.group(2)!);
      int h = mMd.group(3) != null ? int.parse(mMd.group(3)!) : 9;
      final mi = mMd.group(4) != null ? int.parse(mMd.group(4)!) : 0;
      if (isPm && h >= 1 && h <= 11) h += 12;
      if (isAm && h == 12) h = 0;
      final dt = DateTime(now.year, mo, d, h, mi);
      return dt;
    }

    // 2-2) 한국식 날짜: M월 d일 (시/분 생략 가능)
    final reKor = RegExp(r"(\d{1,2})\s*월\s*(\d{1,2})\s*일(?:\s*(\d{1,2})(?::|시)(\d{2})?)?");
    final m2 = reKor.firstMatch(plain);
    if (m2 != null) {
      final mo = int.parse(m2.group(1)!);
      final d = int.parse(m2.group(2)!);
      int h = m2.group(3) != null ? int.parse(m2.group(3)!) : 9;
      final mi = m2.group(4) != null ? int.parse(m2.group(4)!) : 0;
      if (isPm && h >= 1 && h <= 11) h += 12;
      if (isAm && h == 12) h = 0;
      return DateTime(now.year, mo, d, h, mi);
    }

    // 2-3) 상대 날짜(안전망)
    int? dayOffset;
    if (RegExp(r"오늘").hasMatch(sanitized)) dayOffset = 0;
    if (RegExp(r"내일").hasMatch(sanitized)) dayOffset = 1;
    if (RegExp(r"모레").hasMatch(sanitized)) dayOffset = 2;
    if (RegExp(r"글피").hasMatch(sanitized)) dayOffset = 3;
    if (dayOffset != null) {
      final reTime = RegExp(r"(\d{1,2})(?::(\d{2}))?\s*(?:분|시)?");
      final tm = reTime.firstMatch(plain);
      int h = 9;
      int mi = 0;
      if (tm != null) {
        h = int.tryParse(tm.group(1) ?? '9') ?? 9;
        mi = int.tryParse(tm.group(2) ?? '0') ?? 0;
      }
      if (!isAm && !isPm && h >= 1 && h <= 11) h += 12;
      if (isPm && h >= 1 && h <= 11) h += 12;
      if (isAm && h == 12) h = 0;
      final base = DateTime(now.year, now.month, now.day).add(Duration(days: dayOffset));
      return DateTime(base.year, base.month, base.day, h, mi);
    }
    return null;
  }

  // 한국 휴대전화 추출: 우선 AI, 실패 시 정규식
  static Future<String?> extractPhone(String text) async {
    if (!await _isEnabled()) {
      // AI 비활성화 시 정규식으로 직접 처리
      final phoneRegex = RegExp(r'01[0-9]-?\d{3,4}-?\d{4}');
      final match = phoneRegex.firstMatch(text);
      if (match != null) {
        final phone = match.group(0) ?? '';
        return phone.replaceAll(RegExp(r'[^0-9]'), '').replaceAllMapped(RegExp(r'^(01[0-9])(\d{3,4})(\d{4})$'), (m) => '${m[1]}-${m[2]}-${m[3]}');
      }
      return null;
    }

    final aiOut = await _invoke('extract_phone', text);
    if (aiOut != null) return aiOut;

    // 정규식 폴백
    final re = RegExp(r"(01[016789])[- .]?(\d{3,4})[- .]?(\d{4})");
    final m = re.firstMatch(text);
    if (m != null) {
      return '${m.group(1)}-${m.group(2)}-${m.group(3)}';
    }
    return null;
  }

  // 한국인 이름(2~4자 한글) 추출: AI 우선, 정규식 보조
  static Future<String?> extractKoreanName(String text) async {
    if (!await _isEnabled()) {
      // AI 비활성화 시 정규식으로 직접 처리
      final nameRegex = RegExp(r'[가-힣]{2,4}(?:\s+[가-힣]{2,4})?');
      final match = nameRegex.firstMatch(text);
      return match?.group(0);
    }

    final aiOut = await _invoke('extract_name', text);
    if (aiOut != null) return aiOut;

    // 정규식 폴백
    final keyword = RegExp("(?:이름|성함|학생|자녀|아이|원생|보호자|학부모|부모)\\s*[:：]?[\\s\"“”']*([가-힣]{2,4})");
    final m1 = keyword.firstMatch(text);
    if (m1 != null) return m1.group(1);
    final simple = RegExp(r'([가-힣]{2,4})\s*(?:학생|입니다|예요)');
    final m2 = simple.firstMatch(text);
    if (m2 != null) return m2.group(1);
    final justName = RegExp(r'\b([가-힣]{2,4})\b');
    final m3 = justName.firstMatch(text);
    if (m3 != null) return m3.group(1);
    return null;
  }
}
