class OperationSeed {
  const OperationSeed({
    required this.seedKey,
    required this.code,
    required this.name,
    required this.cost,
    required this.initialTimeMs,
    required this.example,
    required this.protocolCode,
    required this.family,
  });

  final String seedKey;
  final String code;
  final String name;

  /// 1/10 스케일 이후의 시드 비용. 운영 DB 값이 다르면 DB가 우선이고 이 숫자는 덮어쓰지 않는다.
  final double cost;
  final int initialTimeMs;
  final String example;
  final String protocolCode;
  final String family;
}

class ProtocolSeed {
  const ProtocolSeed({
    required this.code,
    required this.name,
    required this.scratch,
    required this.answerFormat,
    required this.note,
  });

  final String code;
  final String name;
  final String scratch;
  final String answerFormat;
  final String note;
}

class DraftSeed {
  const DraftSeed({
    required this.code,
    required this.name,
    required this.cost,
    required this.initialTimeMs,
    required this.example,
  });

  final String code;
  final String name;
  final double cost;
  final int initialTimeMs;
  final String example;
}

const protocols = <ProtocolSeed>[
  ProtocolSeed(
    code: 'mental_integer_v1',
    name: '기초 암산 · 정수 답',
    scratch: 'forbidden',
    answerFormat: 'integer',
    note: '한 자리 사칙과 구구단처럼 바로 말하는 유형. 메모와 계산기는 쓰지 않는다. 2026-11-26 운영 정책.',
  ),
  ProtocolSeed(
    code: 'mental_quotrem_v1',
    name: '기초 암산 · 몫과 나머지',
    scratch: 'forbidden',
    answerFormat: 'quotient_remainder',
    note: '구구단 범위에서 나머지가 있는 나눗셈. 몫과 나머지를 둘 다 입력한다.',
  ),
  ProtocolSeed(
    code: 'scratch_integer_v1',
    name: '복합 연산 · 메모 허용 · 정수 답',
    scratch: 'allowed',
    answerFormat: 'integer',
    note: '계산기는 쓰지 않고 메모는 허용한다. 기초 암산과 시간을 섞지 않는다.',
  ),
  ProtocolSeed(
    code: 'scratch_quotrem_v1',
    name: '복합 연산 · 메모 허용 · 몫과 나머지',
    scratch: 'allowed',
    answerFormat: 'quotient_remainder',
    note: '나머지가 있는 복합 나눗셈. 몫만 묻는 프로토콜과 섞지 않는다.',
  ),
];

const naturalSeeds = <OperationSeed>[
  OperationSeed(seedKey: 'N_ADD_11_C0', code: 'nat_add_1d_1d_nc', name: '1자리+1자리 (받아올림 없음)', cost: 0.10, initialTimeMs: 1000, example: '2+3', protocolCode: 'mental_integer_v1', family: 'add'),
  OperationSeed(seedKey: 'N_ADD_11_C1', code: 'nat_add_1d_1d_c1', name: '1자리+1자리 (받아올림 있음)', cost: 0.15, initialTimeMs: 1300, example: '7+8', protocolCode: 'mental_integer_v1', family: 'add'),
  OperationSeed(seedKey: 'N_ADD_21_C0', code: 'nat_add_2d_1d_nc', name: '2자리+1자리 (받아올림 없음)', cost: 0.15, initialTimeMs: 1800, example: '23+4', protocolCode: 'scratch_integer_v1', family: 'add'),
  OperationSeed(seedKey: 'N_ADD_21_C1', code: 'nat_add_2d_1d_c1', name: '2자리+1자리 (받아올림 1회)', cost: 0.22, initialTimeMs: 2300, example: '27+8', protocolCode: 'scratch_integer_v1', family: 'add'),
  OperationSeed(seedKey: 'N_ADD_21_C2', code: 'nat_add_2d_1d_c2', name: '2자리+1자리 (연속 받아올림 2회)', cost: 0.28, initialTimeMs: 3000, example: '98+7', protocolCode: 'scratch_integer_v1', family: 'add'),
  OperationSeed(seedKey: 'N_ADD_22_C0', code: 'nat_add_2d_2d_nc', name: '2자리+2자리 (받아올림 없음)', cost: 0.20, initialTimeMs: 2500, example: '23+45', protocolCode: 'scratch_integer_v1', family: 'add'),
  OperationSeed(seedKey: 'N_ADD_22_C1', code: 'nat_add_2d_2d_c1', name: '2자리+2자리 (받아올림 1회)', cost: 0.30, initialTimeMs: 3000, example: '27+48', protocolCode: 'scratch_integer_v1', family: 'add'),
  OperationSeed(seedKey: 'N_ADD_22_C2', code: 'nat_add_2d_2d_c2', name: '2자리+2자리 (받아올림 2회)', cost: 0.40, initialTimeMs: 3500, example: '78+57', protocolCode: 'scratch_integer_v1', family: 'add'),
  OperationSeed(seedKey: 'N_ADD_3X_C01', code: 'nat_add_3d_23d_c01', name: '3자리+2·3자리 (받아올림 0~1회)', cost: 0.42, initialTimeMs: 4500, example: '234+53', protocolCode: 'scratch_integer_v1', family: 'add'),
  OperationSeed(seedKey: 'N_ADD_33P_C2P', code: 'nat_add_3d_3d_c2p', name: '3자리+3자리 이상 (받아올림 2회 이상)', cost: 0.55, initialTimeMs: 6000, example: '687+586', protocolCode: 'scratch_integer_v1', family: 'add'),
  OperationSeed(seedKey: 'N_SUB_11', code: 'nat_sub_1d_1d', name: '1자리-1자리', cost: 0.10, initialTimeMs: 1200, example: '8-3', protocolCode: 'mental_integer_v1', family: 'sub'),
  OperationSeed(seedKey: 'N_SUB_TEEN_1_B1', code: 'nat_sub_teen_1d_b1', name: '십몇-1자리 (받아내림 있음)', cost: 0.18, initialTimeMs: 1700, example: '13-8', protocolCode: 'mental_integer_v1', family: 'sub'),
  OperationSeed(seedKey: 'N_SUB_21_B0', code: 'nat_sub_2d_1d_nb', name: '2자리-1자리 (받아내림 없음)', cost: 0.16, initialTimeMs: 1800, example: '47-3', protocolCode: 'scratch_integer_v1', family: 'sub'),
  OperationSeed(seedKey: 'N_SUB_21_B1', code: 'nat_sub_2d_1d_b1', name: '2자리-1자리 (받아내림 1회)', cost: 0.25, initialTimeMs: 2500, example: '43-7', protocolCode: 'scratch_integer_v1', family: 'sub'),
  OperationSeed(seedKey: 'N_SUB_22_B0', code: 'nat_sub_2d_2d_nb', name: '2자리-2자리 (받아내림 없음)', cost: 0.22, initialTimeMs: 2500, example: '57-23', protocolCode: 'scratch_integer_v1', family: 'sub'),
  OperationSeed(seedKey: 'N_SUB_22_B1', code: 'nat_sub_2d_2d_b1', name: '2자리-2자리 (받아내림 1회)', cost: 0.35, initialTimeMs: 3500, example: '52-27', protocolCode: 'scratch_integer_v1', family: 'sub'),
  OperationSeed(seedKey: 'N_SUB_3X_B01', code: 'nat_sub_3d_23d_b01', name: '3자리-2·3자리 (받아내림 0~1회)', cost: 0.45, initialTimeMs: 4500, example: '587-234', protocolCode: 'scratch_integer_v1', family: 'sub'),
  OperationSeed(seedKey: 'N_SUB_3X_CHAIN2', code: 'nat_sub_3d_3d_b2', name: '3자리-2·3자리 (연속 받아내림 2회)', cost: 0.60, initialTimeMs: 6000, example: '532-158', protocolCode: 'scratch_integer_v1', family: 'sub'),
  OperationSeed(seedKey: 'N_SUB_ZERO_CROSS', code: 'nat_sub_zero_chain', name: '0이 있는 자리 건너뛰어 받아내림', cost: 0.65, initialTimeMs: 6000, example: '403-27', protocolCode: 'scratch_integer_v1', family: 'sub'),
  OperationSeed(seedKey: 'N_MUL_11', code: 'nat_mul_1d_1d', name: '1자리×1자리', cost: 0.12, initialTimeMs: 1200, example: '7*8', protocolCode: 'mental_integer_v1', family: 'mul'),
  OperationSeed(seedKey: 'N_MUL_POW10', code: 'nat_mul_pow10', name: '자연수에 10, 100, 1000 곱하기', cost: 0.12, initialTimeMs: 1700, example: '23*100', protocolCode: 'scratch_integer_v1', family: 'mul'),
  OperationSeed(seedKey: 'N_MUL_21_C0', code: 'nat_mul_2d_1d_nc', name: '2자리×1자리 (받아올림 없음)', cost: 0.25, initialTimeMs: 3000, example: '21*3', protocolCode: 'scratch_integer_v1', family: 'mul'),
  OperationSeed(seedKey: 'N_MUL_21_C1', code: 'nat_mul_2d_1d_c1', name: '2자리×1자리 (받아올림 1회)', cost: 0.35, initialTimeMs: 4000, example: '23*4', protocolCode: 'scratch_integer_v1', family: 'mul'),
  OperationSeed(seedKey: 'N_MUL_21_C2', code: 'nat_mul_2d_1d_c2', name: '2자리×1자리 (십·일의 자리 모두 올림)', cost: 0.45, initialTimeMs: 5000, example: '87*6', protocolCode: 'scratch_integer_v1', family: 'mul'),
  OperationSeed(seedKey: 'N_MUL_31', code: 'nat_mul_3d_1d', name: '3자리×1자리', cost: 0.55, initialTimeMs: 6000, example: '234*4', protocolCode: 'scratch_integer_v1', family: 'mul'),
  OperationSeed(seedKey: 'N_MUL_22_LOW', code: 'nat_mul_2d_2d_light', name: '2자리×2자리 (받아올림이 적은 경우)', cost: 0.60, initialTimeMs: 8000, example: '12*13', protocolCode: 'scratch_integer_v1', family: 'mul'),
  OperationSeed(seedKey: 'N_MUL_22_HIGH', code: 'nat_mul_2d_2d_heavy', name: '2자리×2자리 (다중 받아올림)', cost: 0.80, initialTimeMs: 12000, example: '87*96', protocolCode: 'scratch_integer_v1', family: 'mul'),
  OperationSeed(seedKey: 'N_MUL_32', code: 'nat_mul_3d_2d', name: '3자리×2자리', cost: 1.05, initialTimeMs: 16000, example: '234*56', protocolCode: 'scratch_integer_v1', family: 'mul'),
  OperationSeed(seedKey: 'N_MUL_33P', code: 'nat_mul_3d_3d', name: '3자리×3자리 이상', cost: 1.50, initialTimeMs: 25000, example: '234*567', protocolCode: 'scratch_integer_v1', family: 'mul'),
  OperationSeed(seedKey: 'N_DIV_BASIC_EXACT', code: 'nat_div_table_exact', name: '구구단 범위 나눗셈 (나누어떨어짐)', cost: 0.15, initialTimeMs: 1500, example: '56/7', protocolCode: 'mental_integer_v1', family: 'div'),
  OperationSeed(seedKey: 'N_DIV_BASIC_REM', code: 'nat_div_table_rem', name: '구구단 범위 나눗셈 (나머지 있음)', cost: 0.22, initialTimeMs: 2500, example: '29/4', protocolCode: 'mental_quotrem_v1', family: 'div'),
  OperationSeed(seedKey: 'N_DIV_21_TENS_EXACT', code: 'nat_div_2d_1d_no_drop', name: '2자리÷1자리 (십의 자리 나누어떨어짐)', cost: 0.30, initialTimeMs: 3500, example: '84/4', protocolCode: 'scratch_integer_v1', family: 'div'),
  OperationSeed(seedKey: 'N_DIV_21_CARRY_EXACT', code: 'nat_div_2d_1d_drop_exact', name: '2자리÷1자리 (내림, 나누어떨어짐)', cost: 0.42, initialTimeMs: 5000, example: '72/3', protocolCode: 'scratch_integer_v1', family: 'div'),
  OperationSeed(seedKey: 'N_DIV_21_CARRY_REM', code: 'nat_div_2d_1d_drop_rem', name: '2자리÷1자리 (내림+나머지)', cost: 0.50, initialTimeMs: 6000, example: '74/3', protocolCode: 'scratch_quotrem_v1', family: 'div'),
  OperationSeed(seedKey: 'N_DIV_31', code: 'nat_div_3d_1d', name: '3자리÷1자리', cost: 0.60, initialTimeMs: 7000, example: '835/4', protocolCode: 'scratch_integer_v1', family: 'div'),
  OperationSeed(seedKey: 'N_DIV_23_2_Q1', code: 'nat_div_23d_2d_q1', name: '2·3자리÷2자리 (몫 1자리)', cost: 0.65, initialTimeMs: 8000, example: '157/23', protocolCode: 'scratch_integer_v1', family: 'div'),
  OperationSeed(seedKey: 'N_DIV_34_2_Q2P', code: 'nat_div_34d_2d_q2p', name: '3·4자리÷2자리 (몫 2자리 이상)', cost: 0.95, initialTimeMs: 13000, example: '936/24', protocolCode: 'scratch_integer_v1', family: 'div'),
];

const draftSeeds = <DraftSeed>[
  DraftSeed(code: 'draft_add_zero', name: '0과 덧셈', cost: 0.05, initialTimeMs: 900, example: '37+0'),
  DraftSeed(code: 'draft_add_hundreds', name: '10·100의 배수 더하기', cost: 0.12, initialTimeMs: 1800, example: '237+400'),
  DraftSeed(code: 'draft_add_3_1_c0', name: '3자리+1자리 (받아올림 없음)', cost: 0.18, initialTimeMs: 2100, example: '235+4'),
  DraftSeed(code: 'draft_add_3_1_c1', name: '3자리+1자리 (받아올림 1회)', cost: 0.25, initialTimeMs: 2700, example: '235+8'),
  DraftSeed(code: 'draft_add_3_1_c2', name: '3자리+1자리 (연속 받아올림 2회 이상)', cost: 0.35, initialTimeMs: 3600, example: '299+8'),
  DraftSeed(code: 'draft_add_3_2_heavy', name: '3자리+2자리 (받아올림 2회 이상)', cost: 0.50, initialTimeMs: 5000, example: '287+58'),
  DraftSeed(code: 'draft_add_4', name: '4자리 이상 덧셈', cost: 0.70, initialTimeMs: 7500, example: '1234+5678'),
  DraftSeed(code: 'draft_sub_zero', name: '0 빼기', cost: 0.05, initialTimeMs: 900, example: '37-0'),
  DraftSeed(code: 'draft_sub_same', name: '같은 수 빼기', cost: 0.05, initialTimeMs: 900, example: '37-37'),
  DraftSeed(code: 'draft_sub_hundreds', name: '10·100의 배수 빼기', cost: 0.15, initialTimeMs: 1900, example: '837-300'),
  DraftSeed(code: 'draft_sub_3_1_nb', name: '3자리-1자리 (받아내림 없음)', cost: 0.20, initialTimeMs: 2200, example: '235-4'),
  DraftSeed(code: 'draft_sub_3_1_b', name: '3자리-1자리 (받아내림 있음)', cost: 0.32, initialTimeMs: 3000, example: '423-7'),
  DraftSeed(code: 'draft_sub_4', name: '4자리 이상 뺄셈', cost: 0.80, initialTimeMs: 8500, example: '5234-1789'),
  DraftSeed(code: 'draft_mul_zero', name: '0을 곱하기', cost: 0.05, initialTimeMs: 900, example: '37*0'),
  DraftSeed(code: 'draft_mul_one', name: '1을 곱하기', cost: 0.05, initialTimeMs: 900, example: '37*1'),
  DraftSeed(code: 'draft_mul_tens', name: '10의 배수 곱하기 (10의 거듭제곱 제외)', cost: 0.30, initialTimeMs: 4500, example: '23*40'),
  DraftSeed(code: 'draft_div_zero_dividend', name: '0을 자연수로 나누기', cost: 0.05, initialTimeMs: 900, example: '0/7'),
  DraftSeed(code: 'draft_div_one', name: '1로 나누기', cost: 0.05, initialTimeMs: 1000, example: '37/1'),
  DraftSeed(code: 'draft_div_same', name: '같은 양의 수로 나누기', cost: 0.05, initialTimeMs: 1000, example: '37/37'),
  DraftSeed(code: 'draft_div_smaller', name: '피제수<제수', cost: 0.10, initialTimeMs: 1800, example: '3/7'),
  DraftSeed(code: 'draft_div_pow10', name: '10의 거듭제곱으로 나누기', cost: 0.12, initialTimeMs: 1800, example: '3700/100'),
  DraftSeed(code: 'draft_div_strip_zeros', name: '끝자리 0을 지우는 나눗셈', cost: 0.20, initialTimeMs: 3000, example: '360/40'),
  DraftSeed(code: 'draft_div_tens_exact_rem', name: '2자리÷1자리 (십의 자리 정확, 나머지)', cost: 0.40, initialTimeMs: 4500, example: '85/4'),
  DraftSeed(code: 'draft_div_internal_zero', name: '몫 중간에 0이 있는 나눗셈', cost: 0.60, initialTimeMs: 7000, example: '612/3'),
  DraftSeed(code: 'draft_div_3digit_divisor', name: '3자리 제수 나눗셈', cost: 1.10, initialTimeMs: 14000, example: '1234/123'),
];

OperationSeed? seedByCode(String code) {
  for (final seed in naturalSeeds) {
    if (seed.code == code) return seed;
  }
  return null;
}
