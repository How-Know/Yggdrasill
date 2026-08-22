const String wonriTimedTestRecommenderKey = 'wonri_timed_v0';
const int wonriTimedTestRecommenderVersion = 0;

const Map<String, double> wonriTimedTestCategoryWeights = <String, double>{
  'essential': 0.40,
  'check': 0.30,
  'practice': 0.20,
  'concept': 0.10,
};

String? normalizeWonriTimedTestCategory(String raw) {
  final compact =
      raw.trim().toLowerCase().replaceAll(RegExp(r'[\s_\-·ㆍ]+'), '');
  if (compact.contains('필수유형') || compact.contains('대표유형')) {
    return 'essential';
  }
  if (compact.contains('확인체크')) return 'check';
  if (compact.contains('연습문제')) return 'practice';
  if (compact.contains('개념원리익히기') || compact.contains('개념익히기')) {
    return 'concept';
  }
  return null;
}

String wonriTimedTestStudentGradingMode({
  required String answerKind,
  required String answerText,
  String? gradingMode,
}) {
  final explicit = (gradingMode ?? '').trim().toLowerCase();
  if (explicit == 'auto' || explicit == 'self') return explicit;

  final kind = answerKind.trim().toLowerCase();
  final text = answerText.trim();
  if (kind == 'objective') return 'auto';
  if (kind != 'subjective' || text.isEmpty) return 'self';
  if (RegExp(r'(^|\s)\(\s*\d\s*\)\s*\S').hasMatch(text)) return 'self';
  if (RegExp(r'\((가|나|다|라|마|바|사)\)').hasMatch(text)) return 'self';
  if (text.contains(r'\begin')) return 'self';
  if (RegExp(r'풀이\s*\d+\s*쪽').hasMatch(text)) return 'self';

  final labels = <String>{};
  final labelPattern = RegExp(
    r'(?:^|[,;\s(])\s*([A-Za-z가-힣][A-Za-z0-9가-힣의 ]{0,15}?)\s*[:=]',
  );
  for (final match in labelPattern.allMatches(text)) {
    final label = (match.group(1) ?? '').trim();
    if (label.isNotEmpty && !RegExp(r'^\d+$').hasMatch(label)) {
      labels.add(label);
    }
  }
  return labels.length >= 2 ? 'self' : 'auto';
}

bool isWonriTimedTestAutoGradable(Map<String, dynamic> row) {
  final kind = '${row['answer_kind'] ?? row['answerKind'] ?? ''}'.trim();
  final text =
      '${row['answer_text'] ?? row['answerText'] ?? row['answer_latex_2d'] ?? row['answerLatex2d'] ?? ''}'
          .trim();
  final mode = '${row['grading_mode'] ?? row['gradingMode'] ?? ''}'.trim();
  return wonriTimedTestStudentGradingMode(
        answerKind: kind,
        answerText: text,
        gradingMode: mode,
      ) ==
      'auto';
}

int wonriTimedTestStableSeed(String value) {
  var hash = 0x811C9DC5;
  for (final codeUnit in value.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash == 0 ? 0x6D2B79F5 : hash;
}

List<T> wonriTimedTestWeightedOrder<T>({
  required Iterable<T> candidates,
  required String Function(T candidate) categoryLabelOf,
  required String Function(T candidate) stableIdOf,
  required String seedMaterial,
}) {
  final preferred = <String, List<T>>{
    for (final key in wonriTimedTestCategoryWeights.keys) key: <T>[],
  };
  final other = <T>[];
  for (final candidate in candidates) {
    final category = normalizeWonriTimedTestCategory(
      categoryLabelOf(candidate),
    );
    if (category == null) {
      other.add(candidate);
    } else {
      preferred[category]!.add(candidate);
    }
  }
  for (final bucket in preferred.values) {
    bucket.sort((a, b) => stableIdOf(a).compareTo(stableIdOf(b)));
  }
  other.sort((a, b) => stableIdOf(a).compareTo(stableIdOf(b)));

  final random = _StableRandom(wonriTimedTestStableSeed(seedMaterial));
  final ordered = <T>[];
  while (preferred.values.any((bucket) => bucket.isNotEmpty)) {
    final available = wonriTimedTestCategoryWeights.entries
        .where((entry) => preferred[entry.key]!.isNotEmpty)
        .toList(growable: false);
    final totalWeight = available.fold<double>(
      0,
      (sum, entry) => sum + entry.value,
    );
    var roll = random.nextDouble() * totalWeight;
    var selectedCategory = available.last.key;
    for (final entry in available) {
      roll -= entry.value;
      if (roll < 0) {
        selectedCategory = entry.key;
        break;
      }
    }
    final bucket = preferred[selectedCategory]!;
    ordered.add(bucket.removeAt(random.nextInt(bucket.length)));
  }

  while (other.isNotEmpty) {
    ordered.add(other.removeAt(random.nextInt(other.length)));
  }
  return ordered;
}

class _StableRandom {
  _StableRandom(int seed) : _state = seed & 0xFFFFFFFF;

  int _state;

  int _nextUint32() {
    var value = _state;
    value ^= (value << 13) & 0xFFFFFFFF;
    value ^= value >> 17;
    value ^= (value << 5) & 0xFFFFFFFF;
    _state = value & 0xFFFFFFFF;
    return _state;
  }

  double nextDouble() => _nextUint32() / 0x100000000;

  int nextInt(int max) {
    if (max <= 1) return 0;
    return _nextUint32() % max;
  }
}
