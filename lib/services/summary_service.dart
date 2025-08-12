class SummaryService {
  // TODO: Replace with real GPT call if API available.
  static Future<String> summarize({String? iconKey, List<String> tags = const <String>[], String? note}) async {
    final base = _labelFromIcon(iconKey) ?? '일정';
    final tagPart = tags.isNotEmpty ? ' · ${tags.join(', ')}' : '';
    if (note != null && note.trim().isNotEmpty) {
      // simple truncation for preview
      final trimmed = note.trim();
      final preview = trimmed.length > 20 ? trimmed.substring(0, 20) + '…' : trimmed;
      return '$base · $preview$tagPart';
    }
    return '$base$tagPart';
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
}


