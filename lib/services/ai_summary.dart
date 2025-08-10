import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class AiSummaryService {
  static Future<String> summarize(String text, {int maxChars = 60}) async {
    final prefs = await SharedPreferences.getInstance();
    final persisted = prefs.getString('openai_api_key') ?? '';
    final defined = const String.fromEnvironment('OPENAI_API_KEY', defaultValue: '');
    final apiKey = persisted.isNotEmpty ? persisted : defined;
    if (apiKey.isEmpty) {
      return toSingleSentence(text, maxChars: maxChars);
    }
    final uri = Uri.parse('https://api.openai.com/v1/chat/completions');
    final body = jsonEncode({
      'model': 'gpt-4o-mini',
      'messages': [
        {
          'role': 'system',
          'content': '너는 텍스트를 한 문장으로 간결하게 요약하는 비서다. 한국어로 한 문장만 출력하고, 줄바꿈 없이 ${maxChars}자 이내로 핵심만 담아라.'
        },
        {
          'role': 'user',
          'content': '다음 텍스트를 한 문장(최대 ${maxChars}자)으로 간결하게 요약해줘. 불필요한 수식어/군더더기 금지:\n$text'
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
    // 1) GPT 우선: ISO 8601 yyyy-MM-ddTHH:mm 형식만 반환(없으면 "null")
    try {
      final prefs = await SharedPreferences.getInstance();
      final persisted = prefs.getString('openai_api_key') ?? '';
      final defined = const String.fromEnvironment('OPENAI_API_KEY', defaultValue: '');
      final apiKey = persisted.isNotEmpty ? persisted : defined;
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
              'content': text
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

    // 2) 정규식 폴백: yyyy-MM-dd HH:mm 또는 M월 d일 (오전/오후) h[:mm], 그리고 오늘/내일/모레/글피 + (오전/오후)h[:mm]
    final now = DateTime.now();

    // 공통: 오전/오후 감지
    bool isAm = RegExp(r"오전").hasMatch(text);
    bool isPm = RegExp(r"오후").hasMatch(text);
    String plain = text.replaceAll('오전', '').replaceAll('오후', '');

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
    // 2-3) 상대 날짜: 오늘/내일/모레/글피 + (시간 선택적)
    int? dayOffset;
    if (RegExp(r"오늘").hasMatch(text)) dayOffset = 0;
    if (RegExp(r"내일").hasMatch(text)) dayOffset = 1;
    if (RegExp(r"모레").hasMatch(text)) dayOffset = 2;
    if (RegExp(r"글피").hasMatch(text)) dayOffset = 3;
    if (dayOffset != null) {
      // 시간 추출: h[:mm] 또는 h시mm분/h시
      final reTime = RegExp(r"(\d{1,2})(?::(\d{2}))?\s*(?:분)?");
      final tm = reTime.firstMatch(plain);
      int h = 9;
      int mi = 0;
      if (tm != null) {
        h = int.parse(tm.group(1)!);
        if (tm.group(2) != null) mi = int.parse(tm.group(2)!);
      }
      if (isPm && h >= 1 && h <= 11) h += 12;
      if (isAm && h == 12) h = 0;
      final base = DateTime(now.year, now.month, now.day).add(Duration(days: dayOffset));
      return DateTime(base.year, base.month, base.day, h, mi);
    }
    return null;
  }
}


