enum HomeworkLearningTrack {
  current('CL', 'Current Learning', '현행'),
  preLearning('PL', 'Pre-learning', '선행'),
  foundational('FL', 'Foundational Learning', '기반학습'),
  extra('EL', 'Extra Learning', '과정 외 학습');

  const HomeworkLearningTrack(this.code, this.englishName, this.koreanName);

  final String code;
  final String englishName;
  final String koreanName;

  static HomeworkLearningTrack fromCode(String? raw) {
    final normalized = normalizeCode(raw);
    return HomeworkLearningTrack.values.firstWhere(
      (track) => track.code == normalized,
      orElse: () => HomeworkLearningTrack.extra,
    );
  }

  static String normalizeCode(String? raw) {
    final normalized = (raw ?? '').trim().toUpperCase();
    for (final track in HomeworkLearningTrack.values) {
      if (track.code == normalized) return normalized;
    }
    return HomeworkLearningTrack.extra.code;
  }

  static bool isValidCode(String? raw) {
    final normalized = (raw ?? '').trim().toUpperCase();
    return HomeworkLearningTrack.values
        .any((track) => track.code == normalized);
  }

  static final RegExp assignmentCodePattern =
      RegExp(r'^(CL|PL|FL|EL)[A-Z]{2}[0-9]{4}$');

  static bool isValidAssignmentCode(String? raw) {
    final normalized = normalizeAssignmentCode(raw);
    return normalized != null;
  }

  static String? normalizeAssignmentCode(String? raw) {
    final normalized =
        (raw ?? '').trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (normalized.isEmpty) return null;
    if (!assignmentCodePattern.hasMatch(normalized)) return null;
    return normalized;
  }

  static String? codeFromAssignmentCode(String? raw) {
    final normalized = normalizeAssignmentCode(raw);
    if (normalized == null || normalized.length < 2) return null;
    return normalized.substring(0, 2);
  }

  static bool assignmentCodeMatchesTrack(String? raw, String? trackCode) {
    final code = normalizeAssignmentCode(raw);
    if (code == null) return false;
    return code.startsWith(normalizeCode(trackCode));
  }

  static bool hasUniformCodes(Iterable<String?> rawCodes) {
    String? first;
    for (final raw in rawCodes) {
      final code = normalizeCode(raw);
      first ??= code;
      if (first != code) return false;
    }
    return true;
  }
}
