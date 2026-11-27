/// 운영 정책 한 버전. 학생 점수 계산은 이 값만 읽고, 코드 곳곳에 숫자를 두지 않는다.
///
/// [targetGradePercent]는 나중에 목표 등급으로 문턱을 조정할 자리만 남겨 둔다.
/// 값이 있어도 이번 산식은 읽지 않는다.
class ModelPolicy {
  const ModelPolicy({
    required this.version,
    required this.formulaId,
    required this.wSpeed,
    required this.wAccuracy,
    required this.masteryAccuracyPct,
    required this.masterySpeed,
    required this.masteryMinAttempts,
    required this.masteryMinDays,
    required this.masteryMinCorrectTimed,
    required this.masteryMinItems,
    required this.calibrationWindowDays,
    required this.perStudentRecentAttempts,
    required this.minStudentAccuracyPct,
    required this.minDistinctDays,
    required this.minCorrectTimedAttempts,
    required this.minDistinctItems,
    required this.empiricalQuantile,
    required this.priorStrengthK,
    required this.minStudentsCandidate,
    required this.minStudentsAutoPublish,
    required this.minAutoChangeFraction,
    required this.maxAutoChangeFraction,
    required this.maxRelativeCiWidth,
    required this.autoPublishEnabled,
    required this.shortTimeFlagMs,
    required this.reasoningBasis,
    required this.reasoningLambdaHypothesis,
    required this.anchorScore,
    required this.anchorIsCap,
    required this.targetGradePercent,
    required this.mul22LightMaxTotalCarry,
    required this.additionBaseSeconds,
    required this.additionDigitSeconds,
    required this.additionCarrySeconds,
    required this.additionChainExtraSeconds,
    required this.additionResultDigitSeconds,
    required this.featureTimeAffectsFluency,
    required this.bootstrapDraws,
    required this.bootstrapSeed,
    required this.note,
  });

  /// 2026-11-26 운영자 정책. 명세의 권장값보다 이 값이 우선이다.
  static const initial = ModelPolicy(
    version: 1,
    formulaId: 'fluency_product_v1',
    wSpeed: 1,
    wAccuracy: 1,
    masteryAccuracyPct: 98,
    masterySpeed: 90,
    masteryMinAttempts: 100,
    masteryMinDays: 3,
    masteryMinCorrectTimed: 50,
    masteryMinItems: 20,
    calibrationWindowDays: 180,
    perStudentRecentAttempts: 100,
    minStudentAccuracyPct: 98,
    minDistinctDays: 3,
    minCorrectTimedAttempts: 50,
    minDistinctItems: 20,
    empiricalQuantile: 0.30,
    priorStrengthK: 20,
    minStudentsCandidate: 10,
    minStudentsAutoPublish: 30,
    minAutoChangeFraction: 0.02,
    maxAutoChangeFraction: 0.10,
    maxRelativeCiWidth: 0.40,
    autoPublishEnabled: true,
    shortTimeFlagMs: 150,
    reasoningBasis: ReasoningBasis.alreadyWeighted,
    reasoningLambdaHypothesis: 5,
    anchorScore: 50,
    anchorIsCap: false,
    targetGradePercent: null,
    mul22LightMaxTotalCarry: 1,
    additionBaseSeconds: 1.0,
    additionDigitSeconds: 0.12,
    additionCarrySeconds: 0.35,
    additionChainExtraSeconds: 0.15,
    additionResultDigitSeconds: 0.20,
    featureTimeAffectsFluency: false,
    bootstrapDraws: 1000,
    bootstrapSeed: 20261126,
    note: '기초 암산과 복합 연산 메모는 프로토콜을 나눈다. 사고 점수는 이미 가중된 합이라 5를 다시 곱하지 않는다. 50점은 최고난도 앵커이고 상한이 아니다.',
  );

  final int version;
  final String formulaId;
  final double wSpeed;
  final double wAccuracy;
  final double masteryAccuracyPct;
  final double masterySpeed;
  final int masteryMinAttempts;
  final int masteryMinDays;
  final int masteryMinCorrectTimed;
  final int masteryMinItems;
  final int calibrationWindowDays;
  final int perStudentRecentAttempts;
  final double minStudentAccuracyPct;
  final int minDistinctDays;
  final int minCorrectTimedAttempts;
  final int minDistinctItems;
  final double empiricalQuantile;
  final double priorStrengthK;
  final int minStudentsCandidate;
  final int minStudentsAutoPublish;
  final double minAutoChangeFraction;
  final double maxAutoChangeFraction;
  final double maxRelativeCiWidth;
  final bool autoPublishEnabled;
  final int shortTimeFlagMs;

  /// 문항 난이도에 들어 있는 사고 점수의 의미.
  final ReasoningBasis reasoningBasis;

  /// 가중 전 점수를 가정한 연구용 배수. [reasoningBasis]가 이미 가중이면 운영 합산에 쓰지 않는다.
  final double reasoningLambdaHypothesis;
  final double anchorScore;
  final bool anchorIsCap;

  /// 목표 등급(퍼센트). null이면 문턱을 움직이지 않는다.
  final double? targetGradePercent;

  /// 두 자리×두 자리 "받아올림이 적은" 임시 기준. 부분곱 올림과 합산 올림의 합.
  final int mul22LightMaxTotalCarry;
  final double additionBaseSeconds;
  final double additionDigitSeconds;
  final double additionCarrySeconds;
  final double additionChainExtraSeconds;
  final double additionResultDigitSeconds;

  /// 항상 거짓으로 유지한다. 속성 추정 시간은 공식 숙련도에 넣지 않는다.
  final bool featureTimeAffectsFluency;
  final int bootstrapDraws;
  final int bootstrapSeed;
  final String note;

  ModelPolicy copyWith({
    int? version,
    double? wSpeed,
    double? wAccuracy,
    double? masteryAccuracyPct,
    double? masterySpeed,
    double? empiricalQuantile,
    double? priorStrengthK,
    int? minStudentsAutoPublish,
    double? maxAutoChangeFraction,
    bool? autoPublishEnabled,
    double? anchorScore,
    String? note,
  }) {
    return ModelPolicy(
      version: version ?? this.version,
      formulaId: formulaId,
      wSpeed: wSpeed ?? this.wSpeed,
      wAccuracy: wAccuracy ?? this.wAccuracy,
      masteryAccuracyPct: masteryAccuracyPct ?? this.masteryAccuracyPct,
      masterySpeed: masterySpeed ?? this.masterySpeed,
      masteryMinAttempts: masteryMinAttempts,
      masteryMinDays: masteryMinDays,
      masteryMinCorrectTimed: masteryMinCorrectTimed,
      masteryMinItems: masteryMinItems,
      calibrationWindowDays: calibrationWindowDays,
      perStudentRecentAttempts: perStudentRecentAttempts,
      minStudentAccuracyPct: minStudentAccuracyPct,
      minDistinctDays: minDistinctDays,
      minCorrectTimedAttempts: minCorrectTimedAttempts,
      minDistinctItems: minDistinctItems,
      empiricalQuantile: empiricalQuantile ?? this.empiricalQuantile,
      priorStrengthK: priorStrengthK ?? this.priorStrengthK,
      minStudentsCandidate: minStudentsCandidate,
      minStudentsAutoPublish: minStudentsAutoPublish ?? this.minStudentsAutoPublish,
      minAutoChangeFraction: minAutoChangeFraction,
      maxAutoChangeFraction: maxAutoChangeFraction ?? this.maxAutoChangeFraction,
      maxRelativeCiWidth: maxRelativeCiWidth,
      autoPublishEnabled: autoPublishEnabled ?? this.autoPublishEnabled,
      shortTimeFlagMs: shortTimeFlagMs,
      reasoningBasis: reasoningBasis,
      reasoningLambdaHypothesis: reasoningLambdaHypothesis,
      anchorScore: anchorScore ?? this.anchorScore,
      anchorIsCap: anchorIsCap,
      targetGradePercent: targetGradePercent,
      mul22LightMaxTotalCarry: mul22LightMaxTotalCarry,
      additionBaseSeconds: additionBaseSeconds,
      additionDigitSeconds: additionDigitSeconds,
      additionCarrySeconds: additionCarrySeconds,
      additionChainExtraSeconds: additionChainExtraSeconds,
      additionResultDigitSeconds: additionResultDigitSeconds,
      featureTimeAffectsFluency: false,
      bootstrapDraws: bootstrapDraws,
      bootstrapSeed: bootstrapSeed,
      note: note ?? this.note,
    );
  }

  Map<String, Object?> toJson() => {
        'formula_id': formulaId,
        'w_speed': wSpeed,
        'w_accuracy': wAccuracy,
        'mastery_accuracy_pct': masteryAccuracyPct,
        'mastery_speed': masterySpeed,
        'mastery_min_attempts': masteryMinAttempts,
        'mastery_min_days': masteryMinDays,
        'mastery_min_correct_timed': masteryMinCorrectTimed,
        'mastery_min_items': masteryMinItems,
        'calibration_window_days': calibrationWindowDays,
        'per_student_recent_attempts': perStudentRecentAttempts,
        'min_student_accuracy_pct': minStudentAccuracyPct,
        'min_distinct_days': minDistinctDays,
        'min_correct_timed_attempts': minCorrectTimedAttempts,
        'min_distinct_items': minDistinctItems,
        'empirical_quantile': empiricalQuantile,
        'prior_strength_k': priorStrengthK,
        'min_students_candidate': minStudentsCandidate,
        'min_students_auto_publish': minStudentsAutoPublish,
        'min_auto_change_fraction': minAutoChangeFraction,
        'max_auto_change_fraction': maxAutoChangeFraction,
        'max_relative_ci_width': maxRelativeCiWidth,
        'auto_publish_enabled': autoPublishEnabled,
        'short_time_flag_ms': shortTimeFlagMs,
        'reasoning_score_basis': reasoningBasis.name,
        'reasoning_lambda_hypothesis': reasoningLambdaHypothesis,
        'anchor_score': anchorScore,
        'anchor_is_cap': anchorIsCap,
        'target_grade_percent': targetGradePercent,
        'mul22_light_max_total_carry': mul22LightMaxTotalCarry,
        'addition_base_seconds': additionBaseSeconds,
        'addition_digit_seconds': additionDigitSeconds,
        'addition_carry_seconds': additionCarrySeconds,
        'addition_chain_extra_seconds': additionChainExtraSeconds,
        'addition_result_digit_seconds': additionResultDigitSeconds,
        'feature_time_affects_fluency': false,
        'bootstrap_draws': bootstrapDraws,
        'bootstrap_seed': bootstrapSeed,
        'note': note,
      };

  static ModelPolicy fromJson(Map<String, Object?> json, {int version = 1}) {
    final basisName = json['reasoning_score_basis'] as String? ?? ReasoningBasis.alreadyWeighted.name;
    final basis = ReasoningBasis.values.where((b) => b.name == basisName).firstOrNull ?? ReasoningBasis.alreadyWeighted;
    double n(String key, double fallback) => (json[key] as num?)?.toDouble() ?? fallback;
    int i(String key, int fallback) => (json[key] as num?)?.toInt() ?? fallback;
    final seed = ModelPolicy.initial;
    return ModelPolicy(
      version: version,
      formulaId: json['formula_id'] as String? ?? seed.formulaId,
      wSpeed: n('w_speed', seed.wSpeed),
      wAccuracy: n('w_accuracy', seed.wAccuracy),
      masteryAccuracyPct: n('mastery_accuracy_pct', seed.masteryAccuracyPct),
      masterySpeed: n('mastery_speed', seed.masterySpeed),
      masteryMinAttempts: i('mastery_min_attempts', seed.masteryMinAttempts),
      masteryMinDays: i('mastery_min_days', seed.masteryMinDays),
      masteryMinCorrectTimed: i('mastery_min_correct_timed', seed.masteryMinCorrectTimed),
      masteryMinItems: i('mastery_min_items', seed.masteryMinItems),
      calibrationWindowDays: i('calibration_window_days', seed.calibrationWindowDays),
      perStudentRecentAttempts: i('per_student_recent_attempts', seed.perStudentRecentAttempts),
      minStudentAccuracyPct: n('min_student_accuracy_pct', seed.minStudentAccuracyPct),
      minDistinctDays: i('min_distinct_days', seed.minDistinctDays),
      minCorrectTimedAttempts: i('min_correct_timed_attempts', seed.minCorrectTimedAttempts),
      minDistinctItems: i('min_distinct_items', seed.minDistinctItems),
      empiricalQuantile: n('empirical_quantile', seed.empiricalQuantile),
      priorStrengthK: n('prior_strength_k', seed.priorStrengthK),
      minStudentsCandidate: i('min_students_candidate', seed.minStudentsCandidate),
      minStudentsAutoPublish: i('min_students_auto_publish', seed.minStudentsAutoPublish),
      minAutoChangeFraction: n('min_auto_change_fraction', seed.minAutoChangeFraction),
      maxAutoChangeFraction: n('max_auto_change_fraction', seed.maxAutoChangeFraction),
      maxRelativeCiWidth: n('max_relative_ci_width', seed.maxRelativeCiWidth),
      autoPublishEnabled: json['auto_publish_enabled'] as bool? ?? seed.autoPublishEnabled,
      shortTimeFlagMs: i('short_time_flag_ms', seed.shortTimeFlagMs),
      reasoningBasis: basis,
      reasoningLambdaHypothesis: n('reasoning_lambda_hypothesis', seed.reasoningLambdaHypothesis),
      anchorScore: n('anchor_score', seed.anchorScore),
      anchorIsCap: json['anchor_is_cap'] as bool? ?? false,
      targetGradePercent: (json['target_grade_percent'] as num?)?.toDouble(),
      mul22LightMaxTotalCarry: i('mul22_light_max_total_carry', seed.mul22LightMaxTotalCarry),
      additionBaseSeconds: n('addition_base_seconds', seed.additionBaseSeconds),
      additionDigitSeconds: n('addition_digit_seconds', seed.additionDigitSeconds),
      additionCarrySeconds: n('addition_carry_seconds', seed.additionCarrySeconds),
      additionChainExtraSeconds: n('addition_chain_extra_seconds', seed.additionChainExtraSeconds),
      additionResultDigitSeconds: n('addition_result_digit_seconds', seed.additionResultDigitSeconds),
      featureTimeAffectsFluency: false,
      bootstrapDraws: i('bootstrap_draws', seed.bootstrapDraws),
      bootstrapSeed: i('bootstrap_seed', seed.bootstrapSeed),
      note: json['note'] as String? ?? seed.note,
    );
  }

  String? validate() {
    if (formulaId != 'fluency_product_v1') return '이번 버전에서 고를 수 있는 산식은 fluency_product_v1 뿐입니다.';
    if (wSpeed < 0.25 || wSpeed > 4 || wAccuracy < 0.25 || wAccuracy > 4) {
      return '속도·정확도 지수는 0.25 이상 4 이하입니다.';
    }
    if (masteryAccuracyPct <= 0 || masteryAccuracyPct > 100) return '숙련 정확도는 0 초과 100 이하입니다.';
    if (masterySpeed <= 0 || masterySpeed > 100) return '숙련 속도는 0 초과 100 이하입니다.';
    if (empiricalQuantile <= 0 || empiricalQuantile >= 1) return '분위수 q는 0과 1 사이입니다.';
    if (priorStrengthK <= 0) return '초기값 강도 k는 0보다 커야 합니다.';
    if (minAutoChangeFraction < 0 || maxAutoChangeFraction <= minAutoChangeFraction || maxAutoChangeFraction > 1) {
      return '자동 적용 변화 폭이 올바르지 않습니다.';
    }
    if (minStudentsCandidate < 1 || minStudentsAutoPublish < minStudentsCandidate) {
      return '자동 적용 인원은 후보 인원 이상이어야 합니다.';
    }
    if (anchorIsCap) return '50점 앵커를 상한으로 두지 않습니다.';
    if (featureTimeAffectsFluency) return '속성 추정 시간은 숙련도에 넣지 않습니다.';
    if (reasoningBasis == ReasoningBasis.unknown) return '사고 점수 의미를 모릅니다. 가중을 다시 곱하지 않습니다.';
    if (targetGradePercent != null && (targetGradePercent! <= 0 || targetGradePercent! > 100)) {
      return '목표 등급은 비우거나 0 초과 100 이하입니다. 이번 산식에는 쓰이지 않습니다.';
    }
    return null;
  }
}

enum ReasoningBasis {
  /// 사고 사전 점수를 그대로 더한 운영값. 배수를 다시 곱하지 않는다.
  alreadyWeighted,

  /// 가중 전 연구 예시. 운영 합산이 아니다.
  raw,

  /// 역산할 근거가 없을 때. 배수를 곱해 보여 주지 않는다.
  unknown,
}

/// 설정 화면이 보여주는 한 줄. 기본값의 의미는 여기서만 적는다.
class PolicyParameter {
  const PolicyParameter({
    required this.key,
    required this.label,
    required this.unit,
    required this.meaning,
    required this.basis,
    required this.affects,
  });

  final String key;
  final String label;
  final String unit;
  final String meaning;
  final String basis;
  final String affects;
}

List<PolicyParameter> policyParameters() => const [
      PolicyParameter(
        key: 'mastery_accuracy_pct',
        label: '숙련 정확도',
        unit: '%',
        meaning: '최근 평가 창에서 이 정확도 이상이어야 숙련으로 본다. 98은 2026-11-26 운영 정책이다.',
        basis: '운영자 지정',
        affects: '숙련 판정. 보정 대상 선별의 정확도 문턱과 같은 숫자로 시작하지만, 보정은 속도 점수 90을 보지 않는다.',
      ),
      PolicyParameter(
        key: 'mastery_speed',
        label: '숙련 속도',
        unit: '점',
        meaning: '적용 기준 시간 대비 속도 점수가 이 값 이상이어야 숙련이다. 90은 2026-11-26 운영 정책이다.',
        basis: '운영자 지정',
        affects: '숙련 판정만. 기준 시간을 고르는 보정에는 쓰지 않는다.',
      ),
      PolicyParameter(
        key: 'prior_strength_k',
        label: '초기값 강도 k',
        unit: '가상 학생 수',
        meaning: '클수록 최초 추정 시간이 오래 남는다. 20은 가상 학생 20명에 비유한 초기 설계값이며 실제 학생 수가 아니다.',
        basis: '운영 가설',
        affects: '후보 기준 시간. 연산 비용과 문항 점수는 바뀌지 않는다.',
      ),
      PolicyParameter(
        key: 'empirical_quantile',
        label: '경험 분위수 q',
        unit: '0~1',
        meaning: '적격 학생 대표시간의 빠른 쪽 분위수. 0.30은 상위 30% 중앙값(약 15백분위)보다 느슨한 기본값이다. 두 방법은 같지 않다.',
        basis: '운영 가설',
        affects: '경험적 기준 시간 Td.',
      ),
      PolicyParameter(
        key: 'min_students_auto_publish',
        label: '자동 적용 최소 학생 수',
        unit: '명',
        meaning: '이 인원 미만이면 후보만 만들고 기준 시간을 바꾸지 않는다.',
        basis: '운영 가설',
        affects: '기준 시간 자동 적용.',
      ),
      PolicyParameter(
        key: 'max_auto_change_fraction',
        label: '자동 적용 최대 변화',
        unit: '비율',
        meaning: '활성 기준 대비 이 비율을 넘는 변화는 사람이 승인하기 전에는 적용하지 않는다. 0.10은 10%다.',
        basis: '안전 조건',
        affects: '기준 시간 자동 적용. 느려지는 쪽과 빨라지는 쪽을 같이 본다.',
      ),
      PolicyParameter(
        key: 'reasoning_score_basis',
        label: '사고 점수 의미',
        unit: 'alreadyWeighted',
        meaning: '문항의 사고 점수는 사고 사전 unit_score의 합이다. 이미 가중된 운영값이라 5를 다시 곱하지 않는다.',
        basis: '기존 운영 방식',
        affects: '문항 종합 점수의 설명. 저장된 문항 점수를 다시 계산하지 않는다.',
      ),
      PolicyParameter(
        key: 'anchor_score',
        label: '최고난도 앵커',
        unit: '점',
        meaning: '가장 어려운 문항을 견주는 눈금이다. 상한이 아니라서 50을 넘겨도 자르지 않는다.',
        basis: '운영자 지정',
        affects: '시뮬레이터의 차이 표시. 점수 재정규화에는 쓰지 않는다.',
      ),
      PolicyParameter(
        key: 'target_grade_percent',
        label: '목표 등급',
        unit: '% 또는 비움',
        meaning: '학생에게 받은 목표 등급에 맞춰 문턱을 조금 바꿀 자리다. 비어 있으면 이번 산식은 정확도 98, 속도 90을 그대로 쓴다.',
        basis: '나중에 조정',
        affects: '아직 아무 점수에도 영향을 주지 않는다.',
      ),
      PolicyParameter(
        key: 'short_time_flag_ms',
        label: '짧은 기록 표시',
        unit: 'ms',
        meaning: '이보다 짧은 기록은 검토 표시만 한다. 150ms는 생리적 한계가 아닌 운영 가설이다. 정오답 판정과는 별개다.',
        basis: '운영 가설',
        affects: '시도의 시간 검토 표시.',
      ),
    ];
