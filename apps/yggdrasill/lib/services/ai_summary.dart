import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/memo.dart';

class AiSummaryService {
  // platform_config에서 API 키 가져오기
  static Future<String> _getApiKey() async {
    try {
      final res = await Supabase.instance.client
          .from('platform_config')
          .select('config_value')
          .eq('config_key', 'openai_api_key')
          .maybeSingle();
      return (res?['config_value'] as String?) ?? '';
    } catch (e) {
      print('[AI] API 키 로드 실패: $e');
      return '';
    }
  }

  static Future<String> summarize(String text, {int maxChars = 60}) async {
    // AI 기능 활성화 확인
    final prefs = await SharedPreferences.getInstance();
    final isEnabled = prefs.getBool('ai_summary_enabled') ?? false;
    if (!isEnabled) {
      return toSingleSentence(text, maxChars: maxChars);
    }
    
    final apiKey = await _getApiKey();
    if (apiKey.isEmpty) {
      return toSingleSentence(text, maxChars: maxChars);
    }
    final uri = Uri.parse('https://api.openai.com/v1/chat/completions');
      final body = jsonEncode({
      'model': 'gpt-4o-mini',
      'messages': [
        {
          'role': 'system',
          'content': '너는 텍스트를 한 줄 키워드로 요약하는 비서다. 한국어로 명사/명사구 중심의 한 줄만 출력하라. 문장부호(.,!?)와 불필요한 조사/수식어를 제거하고, 줄바꿈 없이 ${maxChars}자 이내로 핵심 키워드만 제공하라.'
        },
        {
          'role': 'user',
          'content': '다음 텍스트에서 핵심 키워드를 한 줄(최대 ${maxChars}자)로 요약해줘. 문장은 금지, 쉼표 없이 간결한 명사구로:\n$text'
        }
      ],
      'temperature': 0.2,
      'max_tokens': 80,
    });
    final res = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      },
      body: body,
    );
    if (res.statusCode != 200) {
      return toSingleSentence(text, maxChars: maxChars);
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final choices = json['choices'] as List<dynamic>?;
    final content = choices != null && choices.isNotEmpty
        ? (choices.first['message']?['content'] as String? ?? '')
        : '';
    if (content.isEmpty) return toSingleSentence(text, maxChars: maxChars);
    return toSingleSentence(content, maxChars: maxChars);
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

    // 1) GPT 시도 (상대일이 아닌 경우에만)
    try {
      final prefs = await SharedPreferences.getInstance();
      final isEnabled = prefs.getBool('ai_summary_enabled') ?? false;
      if (!isEnabled) {
        return null;
      }
      
      final apiKey = await _getApiKey();
      if (apiKey.isNotEmpty) {
        final uri = Uri.parse('https://api.openai.com/v1/chat/completions');
        final body = jsonEncode({
          'model': 'gpt-4o-mini',
          'messages': [
            {
              'role': 'system',
              'content': '사용자 문장에서 일정 날짜/시간을 찾아 한국시간 기준 ISO 8601(yyyy-MM-ddTHH:mm) 문자열로만 출력. 없으면 null만 출력.'
            },
            {
              'role': 'user',
              'content': sanitized
            }
          ],
          'temperature': 0.0,
          'max_tokens': 20,
        });
        final res = await http.post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          },
          body: body,
        );
        if (res.statusCode == 200) {
          final json = jsonDecode(res.body) as Map<String, dynamic>;
          final choices = json['choices'] as List<dynamic>?;
          final content = choices != null && choices.isNotEmpty
              ? (choices.first['message']?['content'] as String? ?? '')
              : '';
          final out = content.trim();
          if (out.toLowerCase() != 'null' && out.isNotEmpty) {
            try { return DateTime.parse(out); } catch (_) {}
          }
        }
      }
    } catch (_) {}

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

  // 한국 휴대전화 추출: 우선 GPT, 실패 시 정규식
  static Future<String?> extractPhone(String text) async {
    // 1) GPT 시도: 010-1234-5678 포맷으로만, 없으면 null
    try {
      final prefs = await SharedPreferences.getInstance();
      final isEnabled = prefs.getBool('ai_summary_enabled') ?? false;
      if (!isEnabled) {
        // GPT 비활성화 시 정규식으로 직접 처리
        final phoneRegex = RegExp(r'01[0-9]-?\d{3,4}-?\d{4}');
        final match = phoneRegex.firstMatch(text);
        if (match != null) {
          final phone = match.group(0) ?? '';
          return phone.replaceAll(RegExp(r'[^0-9]'), '').replaceAllMapped(RegExp(r'^(01[0-9])(\d{3,4})(\d{4})$'), (m) => '${m[1]}-${m[2]}-${m[3]}');
        }
        return null;
      }
      
      final apiKey = await _getApiKey();
      if (apiKey.isNotEmpty) {
        final uri = Uri.parse('https://api.openai.com/v1/chat/completions');
        final body = jsonEncode({
          'model': 'gpt-4o-mini',
          'messages': [
            {
              'role': 'system',
              'content': '사용자 문장에서 한국 휴대전화 하나를 010-1234-5678 형식으로만 출력. 없으면 null.'
            },
            {
              'role': 'user',
              'content': text
            }
          ],
          'temperature': 0.0,
          'max_tokens': 10,
        });
        final res = await http.post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          },
          body: body,
        );
        if (res.statusCode == 200) {
          final json = jsonDecode(res.body) as Map<String, dynamic>;
          final choices = json['choices'] as List<dynamic>?;
          final content = choices != null && choices.isNotEmpty
              ? (choices.first['message']?['content'] as String? ?? '')
              : '';
          final out = content.trim();
          if (out.toLowerCase() != 'null' && out.isNotEmpty) {
            return _normalizePhone(out);
          }
        }
      }
    } catch (_) {}

    // 2) 정규식 폴백
    final re = RegExp(r"(01[016789])[- .]?(\d{3,4})[- .]?(\d{4})");
    final m = re.firstMatch(text);
    if (m != null) {
      return '${m.group(1)}-${m.group(2)}-${m.group(3)}';
    }
    return null;
  }

  static String _normalizePhone(String raw) {
    final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length == 11 && digits.startsWith('01')) {
      return digits.substring(0,3) + '-' + digits.substring(3,7) + '-' + digits.substring(7);
    }
    if (digits.length == 10 && digits.startsWith('01')) {
      return digits.substring(0,3) + '-' + digits.substring(3,6) + '-' + digits.substring(6);
    }
    // fallback: keep raw
    return raw;
  }

  // 한국인 이름(2~4자 한글) 추출: GPT 우선, 정규식 보조
  static Future<String?> extractKoreanName(String text) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final isEnabled = prefs.getBool('ai_summary_enabled') ?? false;
      if (!isEnabled) {
        // GPT 비활성화 시 정규식으로 직접 처리
        final nameRegex = RegExp(r'[가-힣]{2,4}(?:\s+[가-힣]{2,4})?');
        final match = nameRegex.firstMatch(text);
        return match?.group(0);
      }
      
      final apiKey = await _getApiKey();
      if (apiKey.isNotEmpty) {
        final uri = Uri.parse('https://api.openai.com/v1/chat/completions');
        final body = jsonEncode({
          'model': 'gpt-4o-mini',
          'messages': [
            {
              'role': 'system',
              'content': '사용자 문장에서 한국인의 고유명사 이름(한글 2~4자)만 출력. 없으면 null. 호칭(학생, 님, 보호자 등) 제외.'
            },
            {
              'role': 'user',
              'content': text
            }
          ],
          'temperature': 0.0,
          'max_tokens': 6,
        });
        final res = await http.post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          },
          body: body,
        );
        if (res.statusCode == 200) {
          final json = jsonDecode(res.body) as Map<String, dynamic>;
          final choices = json['choices'] as List<dynamic>?;
          final content = choices != null && choices.isNotEmpty
              ? (choices.first['message']?['content'] as String? ?? '')
              : '';
          final out = content.trim();
          if (out.toLowerCase() != 'null' && RegExp(r'^[가-힣]{2,4}$').hasMatch(out)) {
            return out;
          }
        }
      }
    } catch (_) {}

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


