import 'dart:convert';
import 'package:http/http.dart' as http;

class KoreanHoliday {
  final int year;
  final int month;
  final int day;
  final String name;
  KoreanHoliday({required this.year, required this.month, required this.day, required this.name});
}

class HolidayService {
  // 간단한 퍼블릭 API 사용: Nager.Date
  // https://date.nager.at/swagger/index.html
  static Future<List<KoreanHoliday>> fetchKoreanPublicHolidays(int year) async {
    final url = Uri.parse('https://date.nager.at/api/v3/PublicHolidays/$year/KR');
    final resp = await http.get(url);
    if (resp.statusCode != 200) return <KoreanHoliday>[];
    final data = jsonDecode(resp.body) as List<dynamic>;
    final List<KoreanHoliday> result = [];
    for (final item in data) {
      final dateStr = item['date'] as String; // e.g., 2025-09-13
      final parts = dateStr.split('-');
      if (parts.length != 3) continue;
      final y = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      final d = int.tryParse(parts[2]);
      final name = (item['localName'] as String?) ?? (item['name'] as String? ?? '공휴일');
      if (y == null || m == null || d == null) continue;
      result.add(KoreanHoliday(year: y, month: m, day: d, name: name));
    }
    return result;
  }
}


