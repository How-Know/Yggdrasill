import 'dart:math' as math;

import 'policy.dart';

/// 정렬한 값의 0-based index h=(n-1)*q, 인접 두 값의 선형 보간. Hyndman-Fan type 7.
double quantileType7(List<double> values, double q) {
  if (values.isEmpty) {
    throw ArgumentError('빈 목록의 분위수는 없습니다.');
  }
  if (q < 0 || q > 1 || q.isNaN) {
    throw ArgumentError('q는 0 이상 1 이하여야 합니다.');
  }
  final sorted = [...values]..sort();
  if (sorted.length == 1) return sorted.first;
  final h = (sorted.length - 1) * q;
  final lo = h.floor();
  final hi = h.ceil();
  if (lo == hi) return sorted[lo];
  final weight = h - lo;
  return sorted[lo] * (1 - weight) + sorted[hi] * weight;
}

double median(List<double> values) => quantileType7(values, 0.5);

/// 결정적 난수. 부트스트랩이 같은 입력이면 같은 구간을 내게 한다.
class Lcg {
  Lcg(this.state);

  int state;

  int nextInt(int mod) {
    if (mod <= 0) throw ArgumentError('mod');
    state = (1664525 * state + 1013904223) & 0x7fffffff;
    return state % mod;
  }
}

class ScoreResult {
  const ScoreResult({
    required this.accuracy,
    required this.speed,
    required this.fluency,
    required this.mastered,
    required this.notes,
  });

  /// 0~100. 분모가 0이면 null(측정 전). 0점과 구분한다.
  final double? accuracy;
  final double? speed;
  final double? fluency;
  final bool mastered;
  final List<String> notes;
}

/// 속도 점수. ratio = 소요/기준 의 중앙값. 기준보다 빠르면 100에서 멈춘다.
double? speedScore(List<double> ratios) {
  if (ratios.isEmpty) return null;
  if (ratios.any((r) => r <= 0 || r.isNaN || r.isInfinite)) {
    throw ArgumentError('시간 비는 유한한 양수여야 합니다.');
  }
  final r = median(ratios);
  return 100 * math.min(1, 1 / r);
}

double? fluencyScore({
  required double? speed,
  required double? accuracy,
  required int accuracyEligibleCount,
  required double wSpeed,
  required double wAccuracy,
}) {
  if (accuracyEligibleCount <= 0 || accuracy == null) return null;
  if (accuracy == 0) return 0;
  if (speed == null) return null;
  return 100 * math.pow(speed / 100, wSpeed).toDouble() * math.pow(accuracy / 100, wAccuracy).toDouble();
}

class AttemptPoint {
  const AttemptPoint({
    required this.outcome,
    required this.accuracyEligible,
    required this.speedEligible,
    required this.elapsedMs,
    required this.referenceMs,
    required this.fingerprint,
    required this.atUtc,
  });

  final AttemptOutcome outcome;
  final bool accuracyEligible;
  final bool speedEligible;
  final int? elapsedMs;
  final int? referenceMs;
  final String fingerprint;
  final DateTime atUtc;

  bool get correct => outcome == AttemptOutcome.correct;
}

enum AttemptOutcome { correct, incorrect, timeout, skipped, abandoned, technicalError, cancelled }

ScoreResult scoreAttempts(List<AttemptPoint> attempts, ModelPolicy policy) {
  final eligible = attempts.where((a) => a.accuracyEligible).toList();
  final notes = <String>[];
  if (policy.targetGradePercent != null) {
    notes.add('목표 등급 ${policy.targetGradePercent}%는 저장만 되어 있고 이 점수에는 쓰이지 않습니다.');
  }
  if (policy.featureTimeAffectsFluency) {
    notes.add('속성 추정 시간은 숙련도에 넣지 않습니다.');
  }
  if (eligible.isEmpty) {
    return ScoreResult(accuracy: null, speed: null, fluency: null, mastered: false, notes: [...notes, '측정 전']);
  }
  final correct = eligible.where((a) => a.correct).length;
  final accuracy = 100 * correct / eligible.length;
  final ratios = <double>[];
  for (final a in eligible) {
    if (!a.speedEligible || !a.correct) continue;
    final elapsed = a.elapsedMs;
    final reference = a.referenceMs;
    if (elapsed == null || reference == null || reference <= 0 || elapsed <= 0) continue;
    if (elapsed < policy.shortTimeFlagMs) {
      notes.add('${elapsed}ms 기록은 ${policy.shortTimeFlagMs}ms보다 짧아 검토 표시입니다. 오답으로 바꾸지는 않습니다.');
    }
    ratios.add(elapsed / reference);
  }
  final speed = speedScore(ratios);
  if (speed == null) notes.add('시간 적격 정답이 없어 속도는 측정 전입니다.');
  final fluency = fluencyScore(
    speed: speed,
    accuracy: accuracy,
    accuracyEligibleCount: eligible.length,
    wSpeed: policy.wSpeed,
    wAccuracy: policy.wAccuracy,
  );
  final days = eligible.map((a) => seoulDay(a.atUtc)).toSet().length;
  final items = eligible.map((a) => a.fingerprint).toSet().length;
  final mastered = accuracy >= policy.masteryAccuracyPct &&
      speed != null &&
      speed >= policy.masterySpeed &&
      eligible.length >= policy.masteryMinAttempts &&
      days >= policy.masteryMinDays &&
      ratios.length >= policy.masteryMinCorrectTimed &&
      items >= policy.masteryMinItems;
  if (!mastered) {
    notes.add('숙련 판정은 정확도·속도·표본을 같이 봅니다. 종합 점수만으로 정하지 않습니다.');
  }
  return ScoreResult(accuracy: accuracy, speed: speed, fluency: fluency, mastered: mastered, notes: notes);
}

/// 유형별 점수의 같은 가중 평균. null(측정 전)은 0점으로 넣지 않는다.
double? equalWeightMean(List<double?> scores) {
  final known = [for (final s in scores) if (s != null) s];
  if (known.isEmpty) return null;
  return known.reduce((a, b) => a + b) / known.length;
}

DateTime seoulDay(DateTime utc) {
  final local = utc.toUtc().add(const Duration(hours: 9));
  return DateTime.utc(local.year, local.month, local.day);
}
