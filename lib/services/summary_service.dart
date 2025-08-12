class SummaryService {
  // TODO: Replace with real GPT call if API available.
  static Future<String> summarize({String? iconKey, List<String> tags = const <String>[], String? note}) async {
    // 한줄 요약 기본 규칙
    final base = _labelFromIcon(iconKey) ?? '';
    final parts = <String>[];
    if (base.isNotEmpty) parts.add(base);
    if (note != null && note.trim().isNotEmpty) parts.add(note.trim());
    if (tags.isNotEmpty) parts.add(tags.join(', '));
    final raw = parts.join(' · ');
    if (raw.isEmpty) return '일정';
    return _toSingleSentence(raw, maxChars: 50);
  }

  static String? _labelFromIcon(String? iconKey) {
    switch (iconKey) {
      case 'holiday':
        return '휴강';
      case 'exam':
        return '시험';
      case 'vacation_start':
        return '방학식';
      case 'school_open':
        return '개학식';
      case 'special_lecture':
        return '특강';
      case 'counseling':
        return '상담';
      case 'notice':
        return '공지';
      case 'payment':
        return '납부';
      default:
        return null;
    }
  }

  // ---- Local helpers (fallback sentence clip) ----
  static String _toSingleSentence(String raw, {int maxChars = 60}) {
    var s = raw.replaceAll('\n', ' ').replaceAll('\r', ' ');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    final endIdx = _firstSentenceEndIndex(s);
    if (endIdx != -1) s = s.substring(0, endIdx + 1);
    if (s.runes.length <= maxChars) return s;
    final clipped = _clipRunes(s, maxChars);
    final clippedEnd = _firstSentenceEndIndex(clipped);
    if (clippedEnd != -1) return clipped.substring(0, clippedEnd + 1);
    return '$clipped…';
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
}


