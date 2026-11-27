import 'features.dart';

const classificationRuleVersion = 'natural_rules_v1';

class Classification {
  const Classification({
    required this.code,
    required this.status,
    required this.candidates,
    required this.draftApplied,
    required this.tags,
  });

  /// 활성 유형 코드. 없으면 null.
  final String? code;

  /// matched | unclassified | integer_domain | rejected
  final String status;
  final List<String> candidates;
  final bool draftApplied;
  final List<String> tags;
}

Classification classifyExpression(String raw, {Set<String> activeDrafts = const {}}) {
  final parsed = parseNaturalExpression(raw);
  if (parsed.status == ParseStatus.divZero) {
    return const Classification(code: null, status: 'rejected', candidates: [], draftApplied: false, tags: ['div_zero']);
  }
  if (!parsed.ok) {
    return Classification(
      code: null,
      status: 'rejected',
      candidates: const [],
      draftApplied: false,
      tags: [parsed.status.name],
    );
  }
  return classifyFeatures(featuresOf(parsed.left!, parsed.right!, parsed.op!, parsed.display), activeDrafts: activeDrafts);
}

Classification classifyFeatures(NaturalFeatures features, {Set<String> activeDrafts = const {}}) {
  if (features.op == ArithmeticOp.div && features.right == BigInt.zero) {
    return const Classification(code: null, status: 'rejected', candidates: [], draftApplied: false, tags: ['div_zero']);
  }
  if (features.aLessThanB) {
    return const Classification(
      code: null,
      status: 'integer_domain',
      candidates: [],
      draftApplied: false,
      tags: ['negative_result'],
    );
  }
  final tags = <String>[
    if (features.containsZeroOperand) 'zero_operand',
    if (features.containsOneOperand) 'one_operand',
    if (features.equalOperands) 'equal_operands',
    if (features.powerOfTenOperand) 'power_of_ten',
    if (features.multipleOfTenOperand) 'multiple_of_ten',
    if (features.leadingCarry == true) 'leading_carry',
    if ((features.zeroCrossingCount ?? 0) > 0) 'zero_crossing',
    if (features.hasRemainder) 'remainder',
    if ((features.internalQuotientZeroCount ?? 0) > 0) 'internal_quotient_zero',
  ];
  final drafts = _matchingDrafts(features);
  for (final code in drafts) {
    if (activeDrafts.contains(code)) {
      return Classification(code: code, status: 'matched', candidates: drafts, draftApplied: true, tags: tags);
    }
  }
  final existing = _matchExisting(features);
  return Classification(
    code: existing,
    status: existing == null ? 'unclassified' : 'matched',
    candidates: drafts,
    draftApplied: false,
    tags: tags,
  );
}

String? _matchExisting(NaturalFeatures f) {
  switch (f.op) {
    case ArithmeticOp.add:
      return _matchAdd(f);
    case ArithmeticOp.sub:
      return _matchSub(f);
    case ArithmeticOp.mul:
      return _matchMul(f);
    case ArithmeticOp.div:
      return _matchDiv(f);
  }
}

(int, int) _sortedDigits(NaturalFeatures f) {
  final a = f.leftDigits;
  final b = f.rightDigits;
  return a >= b ? (a, b) : (b, a);
}

String? _matchAdd(NaturalFeatures f) {
  final (hi, lo) = _sortedDigits(f);
  final carry = f.carryCount ?? 0;
  final chain = f.carryChainLength ?? 0;
  if (hi == 1 && lo == 1) return carry == 0 ? 'nat_add_1d_1d_nc' : 'nat_add_1d_1d_c1';
  if (hi == 2 && lo == 1 && chain >= 2) return 'nat_add_2d_1d_c2';
  if (hi == 2 && lo == 1 && carry == 1) return 'nat_add_2d_1d_c1';
  if (hi == 2 && lo == 1 && carry == 0) return 'nat_add_2d_1d_nc';
  if (hi == 2 && lo == 2 && carry == 0) return 'nat_add_2d_2d_nc';
  if (hi == 2 && lo == 2 && carry == 1) return 'nat_add_2d_2d_c1';
  if (hi == 2 && lo == 2 && carry >= 2) return 'nat_add_2d_2d_c2';
  if (hi == 3 && lo >= 2 && lo <= 3 && carry <= 1) return 'nat_add_3d_23d_c01';
  if (hi >= 3 && lo >= 3 && carry >= 2) return 'nat_add_3d_3d_c2p';
  return null;
}

String? _matchSub(NaturalFeatures f) {
  if ((f.zeroCrossingCount ?? 0) > 0) return 'nat_sub_zero_chain';
  final a = f.left;
  final b = f.right;
  if (a >= BigInt.from(10) && a <= BigInt.from(18) && b >= BigInt.one && b <= BigInt.from(9) && (f.borrowCount ?? 0) >= 1) {
    return 'nat_sub_teen_1d_b1';
  }
  if (f.leftDigits == 1 && f.rightDigits == 1) return 'nat_sub_1d_1d';
  final borrow = f.borrowCount ?? 0;
  final chain = f.borrowChainLength ?? 0;
  if (f.leftDigits == 2 && f.rightDigits == 1 && borrow == 0) return 'nat_sub_2d_1d_nb';
  if (f.leftDigits == 2 && f.rightDigits == 1 && borrow >= 1) return 'nat_sub_2d_1d_b1';
  if (f.leftDigits == 2 && f.rightDigits == 2 && borrow == 0) return 'nat_sub_2d_2d_nb';
  if (f.leftDigits == 2 && f.rightDigits == 2 && borrow >= 1) return 'nat_sub_2d_2d_b1';
  if (f.leftDigits == 3 && f.rightDigits >= 2 && f.rightDigits <= 3 && borrow <= 1) return 'nat_sub_3d_23d_b01';
  if (f.leftDigits == 3 && f.rightDigits >= 2 && f.rightDigits <= 3 && chain >= 2) return 'nat_sub_3d_3d_b2';
  return null;
}

String? _matchMul(NaturalFeatures f) {
  if (_isListedPowerOfTen(f.left) || _isListedPowerOfTen(f.right)) return 'nat_mul_pow10';
  final (hi, lo) = _sortedDigits(f);
  final carry = f.multiplicationCarryCount ?? 0;
  if (hi == 1 && lo == 1) return 'nat_mul_1d_1d';
  if (hi == 2 && lo == 1) {
    if (carry == 0) return 'nat_mul_2d_1d_nc';
    if (_bothColumnsCarry(f)) return 'nat_mul_2d_1d_c2';
    return 'nat_mul_2d_1d_c1';
  }
  if (hi == 3 && lo == 1) return 'nat_mul_3d_1d';
  if (hi == 2 && lo == 2) {
    final total = carry + (f.partialSumCarryCount ?? 0);
    return total <= 1 ? 'nat_mul_2d_2d_light' : 'nat_mul_2d_2d_heavy';
  }
  if (hi == 3 && lo == 2) return 'nat_mul_3d_2d';
  if (hi >= 3 && lo >= 3) return 'nat_mul_3d_3d';
  return null;
}

bool _bothColumnsCarry(NaturalFeatures f) {
  final big = f.leftDigits >= f.rightDigits ? f.left : f.right;
  final small = f.leftDigits >= f.rightDigits ? f.right : f.left;
  if (digitCount(big) != 2 || digitCount(small) != 1) return false;
  final units = (big % BigInt.from(10)).toInt() * small.toInt();
  if (units < 10) return false;
  final tens = (big ~/ BigInt.from(10)).toInt() * small.toInt() + units ~/ 10;
  return tens >= 10;
}

bool _isListedPowerOfTen(BigInt n) => n == BigInt.from(10) || n == BigInt.from(100) || n == BigInt.from(1000);

String? _matchDiv(NaturalFeatures f) {
  final divisor = f.right;
  final dividend = f.left;
  final q = f.quotient ?? BigInt.zero;
  final rem = f.remainder ?? BigInt.zero;
  if (divisor >= BigInt.one && divisor <= BigInt.from(9) && q >= BigInt.one && q <= BigInt.from(9)) {
    if (rem == BigInt.zero) return 'nat_div_table_exact';
    if (dividend < divisor * BigInt.from(10)) return 'nat_div_table_rem';
  }
  if (f.leftDigits == 2 && f.rightDigits == 1 && rem == BigInt.zero && _tensAndOnesExact(dividend, divisor)) {
    return 'nat_div_2d_1d_no_drop';
  }
  if (f.leftDigits == 2 && f.rightDigits == 1 && rem == BigInt.zero) return 'nat_div_2d_1d_drop_exact';
  if (f.leftDigits == 2 && f.rightDigits == 1 && rem > BigInt.zero && !_tensDigitExact(dividend, divisor)) {
    return 'nat_div_2d_1d_drop_rem';
  }
  if (f.leftDigits == 3 && f.rightDigits == 1) return 'nat_div_3d_1d';
  if (f.rightDigits == 2 && f.leftDigits >= 2 && f.leftDigits <= 3 && (f.quotientDigits ?? 0) == 1) {
    return 'nat_div_23d_2d_q1';
  }
  if (f.rightDigits == 2 && f.leftDigits >= 3 && f.leftDigits <= 4 && (f.quotientDigits ?? 0) >= 2) {
    return 'nat_div_34d_2d_q2p';
  }
  return null;
}

bool _tensAndOnesExact(BigInt dividend, BigInt divisor) {
  final tens = dividend ~/ BigInt.from(10);
  final ones = dividend % BigInt.from(10);
  return tens % divisor == BigInt.zero && ones % divisor == BigInt.zero;
}

bool _tensDigitExact(BigInt dividend, BigInt divisor) => (dividend ~/ BigInt.from(10)) % divisor == BigInt.zero;

List<String> _matchingDrafts(NaturalFeatures f) {
  final hits = <String>[];
  void add(String code, bool when) {
    if (when) hits.add(code);
  }

  add('draft_add_zero', f.op == ArithmeticOp.add && f.containsZeroOperand);
  add('draft_sub_zero', f.op == ArithmeticOp.sub && f.right == BigInt.zero);
  add('draft_sub_same', f.op == ArithmeticOp.sub && f.equalOperands);
  add('draft_mul_zero', f.op == ArithmeticOp.mul && f.containsZeroOperand);
  add('draft_mul_one', f.op == ArithmeticOp.mul && f.containsOneOperand && !f.containsZeroOperand);
  add('draft_div_zero_dividend', f.op == ArithmeticOp.div && f.left == BigInt.zero);
  add('draft_div_one', f.op == ArithmeticOp.div && f.divisorIsOne);
  add('draft_div_same', f.op == ArithmeticOp.div && f.equalOperands && f.right != BigInt.zero);
  add('draft_div_smaller', f.op == ArithmeticOp.div && f.dividendLessThanDivisor);
  final (hi, lo) = _sortedDigits(f);
  final carry = f.carryCount ?? 0;
  add('draft_add_3_1_c0', f.op == ArithmeticOp.add && hi == 3 && lo == 1 && carry == 0);
  add('draft_add_3_1_c1', f.op == ArithmeticOp.add && hi == 3 && lo == 1 && carry == 1);
  add('draft_add_3_1_c2', f.op == ArithmeticOp.add && hi == 3 && lo == 1 && carry >= 2);
  add(
    'draft_mul_tens',
    f.op == ArithmeticOp.mul && f.multipleOfTenOperand && !f.powerOfTenOperand,
  );
  add(
    'draft_div_tens_exact_rem',
    f.op == ArithmeticOp.div &&
        f.leftDigits == 2 &&
        f.rightDigits == 1 &&
        f.hasRemainder &&
        _tensDigitExact(f.left, f.right),
  );
  add(
    'draft_div_pow10',
    f.op == ArithmeticOp.div && _isListedPowerOfTen(f.right) && (f.remainder ?? BigInt.one) == BigInt.zero,
  );
  add(
    'draft_div_strip_zeros',
    f.op == ArithmeticOp.div &&
        f.left % BigInt.from(10) == BigInt.zero &&
        f.right % BigInt.from(10) == BigInt.zero &&
        f.right > BigInt.one &&
        !_isListedPowerOfTen(f.right),
  );
  add('draft_div_internal_zero', f.op == ArithmeticOp.div && (f.internalQuotientZeroCount ?? 0) > 0);
  add('draft_sub_3_1_nb', f.op == ArithmeticOp.sub && f.leftDigits == 3 && f.rightDigits == 1 && (f.borrowCount ?? 0) == 0);
  add('draft_sub_3_1_b', f.op == ArithmeticOp.sub && f.leftDigits == 3 && f.rightDigits == 1 && (f.borrowCount ?? 1) >= 1 && (f.zeroCrossingCount ?? 0) == 0);
  add(
    'draft_add_hundreds',
    f.op == ArithmeticOp.add && _hundreds(f.left, f.right),
  );
  add('draft_sub_hundreds', f.op == ArithmeticOp.sub && f.right >= BigInt.from(100) && f.right % BigInt.from(100) == BigInt.zero);
  add('draft_add_3_2_heavy', f.op == ArithmeticOp.add && hi == 3 && lo == 2 && carry >= 2);
  add('draft_add_4', f.op == ArithmeticOp.add && hi >= 4);
  add('draft_sub_4', f.op == ArithmeticOp.sub && f.leftDigits >= 4 && (f.zeroCrossingCount ?? 0) == 0);
  add('draft_div_3digit_divisor', f.op == ArithmeticOp.div && f.rightDigits >= 3);
  return hits;
}

bool _hundreds(BigInt a, BigInt b) {
  bool hit(BigInt n) => n >= BigInt.from(100) && n % BigInt.from(100) == BigInt.zero;
  return hit(a) || hit(b);
}
