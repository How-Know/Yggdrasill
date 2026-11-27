import 'policy.dart';
import 'scoring.dart';

enum ReferenceDecision { keepActive, candidateOnly, needsApproval, autoApply }

class CalibrationResult {
  const CalibrationResult({
    required this.studentCount,
    required this.empiricalMs,
    required this.candidateMs,
    required this.dataWeight,
    required this.decision,
    required this.reasons,
    required this.ciLowMs,
    required this.ciHighMs,
    required this.changeFraction,
    required this.mediansMs,
  });

  final int studentCount;
  final double? empiricalMs;
  final double? candidateMs;
  final double? dataWeight;
  final ReferenceDecision decision;
  final List<String> reasons;
  final double? ciLowMs;
  final double? ciHighMs;
  final double? changeFraction;
  final List<double> mediansMs;
}

class StudentWindow {
  const StudentWindow({required this.studentId, required this.attempts});

  final String studentId;
  final List<AttemptPoint> attempts;
}

class CalibrationRequest {
  const CalibrationRequest({
    required this.students,
    required this.cutoffUtc,
    required this.initialMs,
    required this.activeMs,
    required this.policy,
  });

  final List<StudentWindow> students;
  final DateTime cutoffUtc;

  /// 활성 시드의 최초값. 이전에 보정된 기준을 여기 넣지 않는다.
  final double initialMs;

  /// 지금 평가에 쓰는 기준. 없으면 [initialMs]와 같다고 본다.
  final double? activeMs;
  final ModelPolicy policy;
}

CalibrationResult calibrate(CalibrationRequest request) {
  final policy = request.policy;
  if (request.initialMs <= 0) {
    throw ArgumentError('최초 기준 시간은 양수여야 합니다.');
  }
  final windowStart = request.cutoffUtc.subtract(Duration(days: policy.calibrationWindowDays));
  final medians = <double>[];
  final reasons = <String>[];
  for (final student in request.students) {
    final picked = _recent(student.attempts, windowStart, request.cutoffUtc, policy.perStudentRecentAttempts);
    final eligible = picked.where((a) => a.accuracyEligible).toList();
    if (eligible.isEmpty) {
      reasons.add('${student.studentId}: 평가 시도 없음');
      continue;
    }
    final correct = eligible.where((a) => a.correct).length;
    final accuracy = 100 * correct / eligible.length;
    final days = eligible.map((a) => seoulDay(a.atUtc)).toSet().length;
    final items = eligible.map((a) => a.fingerprint).toSet().length;
    final times = <double>[
      for (final a in eligible)
        if (a.correct && a.speedEligible && a.elapsedMs != null && a.elapsedMs! > 0) a.elapsedMs!.toDouble(),
    ];
    if (accuracy < policy.minStudentAccuracyPct) {
      reasons.add('${student.studentId}: 정확도 ${accuracy.toStringAsFixed(1)}%');
      continue;
    }
    if (days < policy.minDistinctDays) {
      reasons.add('${student.studentId}: 측정일 $days일');
      continue;
    }
    if (items < policy.minDistinctItems) {
      reasons.add('${student.studentId}: 서로 다른 문항 $items개');
      continue;
    }
    if (times.length < policy.minCorrectTimedAttempts) {
      reasons.add('${student.studentId}: 시간 적격 정답 ${times.length}개');
      continue;
    }
    medians.add(median(times));
  }
  final n = medians.length;
  if (n == 0) {
    return CalibrationResult(
      studentCount: 0,
      empiricalMs: null,
      candidateMs: null,
      dataWeight: null,
      decision: ReferenceDecision.keepActive,
      reasons: [...reasons, '적격 학생이 없어 활성 기준을 유지합니다.'],
      ciLowMs: null,
      ciHighMs: null,
      changeFraction: null,
      mediansMs: const [],
    );
  }
  final td = quantileType7(medians, policy.empiricalQuantile);
  if (n < policy.minStudentsCandidate) {
    return CalibrationResult(
      studentCount: n,
      empiricalMs: td,
      candidateMs: null,
      dataWeight: n / (policy.priorStrengthK + n),
      decision: ReferenceDecision.keepActive,
      reasons: [...reasons, '적격 학생 $n명은 ${policy.minStudentsCandidate}명 미만이라 후보를 만들지 않습니다. 활성 기준은 최초값으로 되돌리지 않습니다.'],
      ciLowMs: null,
      ciHighMs: null,
      changeFraction: null,
      mediansMs: medians,
    );
  }
  final candidate = shrink(t0: request.initialMs, td: td, k: policy.priorStrengthK, n: n);
  final baseline = request.activeMs ?? request.initialMs;
  final change = (candidate - baseline).abs() / baseline;
  final weight = n / (policy.priorStrengthK + n);
  double? ciLow;
  double? ciHigh;
  if (n >= 20) {
    final interval = bootstrapCandidate(
      medians: medians,
      q: policy.empiricalQuantile,
      t0: request.initialMs,
      k: policy.priorStrengthK,
      draws: policy.bootstrapDraws,
      seed: policy.bootstrapSeed,
    );
    ciLow = interval.$1;
    ciHigh = interval.$2;
  }
  final decisionReasons = <String>[...reasons];
  var decision = ReferenceDecision.autoApply;
  if (change < policy.minAutoChangeFraction) {
    decision = ReferenceDecision.candidateOnly;
    decisionReasons.add('변화 ${(change * 100).toStringAsFixed(1)}%는 ${policy.minAutoChangeFraction * 100}% 미만이라 적용하지 않고 후보만 남깁니다.');
  } else if (n < policy.minStudentsAutoPublish) {
    decision = ReferenceDecision.needsApproval;
    decisionReasons.add('적격 학생 $n/${policy.minStudentsAutoPublish}명. 자동 적용하지 않습니다.');
  } else if (change > policy.maxAutoChangeFraction) {
    decision = ReferenceDecision.needsApproval;
    decisionReasons.add('변화 ${(change * 100).toStringAsFixed(1)}%는 ${policy.maxAutoChangeFraction * 100}%를 넘어 관리자 승인 전입니다.');
  } else if (ciLow == null || ciHigh == null) {
    decision = ReferenceDecision.needsApproval;
    decisionReasons.add('표본이 20명 미만이라 구간을 계산하지 않았습니다. 자동 적용하지 않습니다.');
  } else if ((ciHigh - ciLow) / candidate > policy.maxRelativeCiWidth) {
    decision = ReferenceDecision.needsApproval;
    decisionReasons.add('구간 폭이 후보의 ${policy.maxRelativeCiWidth * 100}%를 넘어 자동 적용하지 않습니다.');
  } else if (!policy.autoPublishEnabled) {
    decision = ReferenceDecision.needsApproval;
    decisionReasons.add('자동 적용이 꺼져 있어 후보만 계산했습니다.');
  } else {
    decisionReasons.add('안전 조건을 만족해 기준 시간만 자동 적용할 수 있습니다. 연산 비용은 바꾸지 않습니다.');
  }
  return CalibrationResult(
    studentCount: n,
    empiricalMs: td,
    candidateMs: candidate,
    dataWeight: weight,
    decision: decision,
    reasons: decisionReasons,
    ciLowMs: ciLow,
    ciHighMs: ciHigh,
    changeFraction: change,
    mediansMs: medians,
  );
}

double shrink({required double t0, required double td, required double k, required int n}) {
  if (k <= 0 || n < 0 || t0 <= 0 || td <= 0) {
    throw ArgumentError('수축 추정 입력이 올바르지 않습니다.');
  }
  return (k * t0 + n * td) / (k + n);
}

/// 학생 대표값을 단위로 다시 뽑아 후보의 2.5%·97.5%를 구한다.
(double, double) bootstrapCandidate({
  required List<double> medians,
  required double q,
  required double t0,
  required double k,
  required int draws,
  required int seed,
}) {
  final rng = Lcg(seed);
  final samples = <double>[];
  for (var i = 0; i < draws; i++) {
    final resample = [for (var j = 0; j < medians.length; j++) medians[rng.nextInt(medians.length)]];
    final td = quantileType7(resample, q);
    samples.add(shrink(t0: t0, td: td, k: k, n: medians.length));
  }
  return (quantileType7(samples, 0.025), quantileType7(samples, 0.975));
}

/// 시뮬레이터용 가상 학생. 모두 같은 시간이고 표본 조건을 채운다. 운영 기록이 아니다.
List<StudentWindow> uniformStudents({
  required int count,
  required int elapsedMs,
  int attempts = 50,
}) {
  final start = DateTime.utc(2026, 5, 1);
  return [
    for (var s = 0; s < count; s++)
      StudentWindow(
        studentId: 'virtual-$s',
        attempts: [
          for (var i = 0; i < attempts; i++)
            AttemptPoint(
              outcome: AttemptOutcome.correct,
              accuracyEligible: true,
              speedEligible: true,
              elapsedMs: elapsedMs,
              referenceMs: 1000,
              fingerprint: 'item${i % 20}',
              atUtc: start.add(Duration(hours: i)),
            ),
        ],
      ),
  ];
}

List<AttemptPoint> _recent(List<AttemptPoint> attempts, DateTime start, DateTime cutoff, int limit) {
  final inWindow = [
    for (final a in attempts)
      if (!a.atUtc.isBefore(start) && !a.atUtc.isAfter(cutoff)) a,
  ]..sort((a, b) => b.atUtc.compareTo(a.atUtc));
  if (inWindow.length <= limit) return inWindow;
  return inWindow.sublist(0, limit);
}
