class KoreanMatcher {
  const KoreanMatcher._();

  static const _initials = [
    'ㄱ',
    'ㄲ',
    'ㄴ',
    'ㄷ',
    'ㄸ',
    'ㄹ',
    'ㅁ',
    'ㅂ',
    'ㅃ',
    'ㅅ',
    'ㅆ',
    'ㅇ',
    'ㅈ',
    'ㅉ',
    'ㅊ',
    'ㅋ',
    'ㅌ',
    'ㅍ',
    'ㅎ',
  ];

  static bool matches(String value, String query) {
    final normalizedValue = value.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    final normalizedQuery = query.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    if (normalizedQuery.isEmpty) return true;
    if (normalizedValue.contains(normalizedQuery)) return true;
    return initialsOf(normalizedValue).contains(normalizedQuery);
  }

  static String initialsOf(String value) {
    final result = StringBuffer();
    for (final rune in value.runes) {
      if (rune >= 0xAC00 && rune <= 0xD7A3) {
        result.write(_initials[(rune - 0xAC00) ~/ 588]);
      } else {
        result.write(String.fromCharCode(rune));
      }
    }
    return result.toString();
  }
}
