/// 문제은행 상단 교육과정 체크박스 필터 상태.
class ProblemBankCurriculumFilter {
  const ProblemBankCurriculumFilter({
    this.allSelected = false,
    this.latestSelected = true,
    this.previousSelected = false,
    this.legacyCodes = const <String>{},
  });

  static const String latestCode = 'rev_2022';
  static const String previousCode = 'rev_2015';

  static const List<String> legacyCodesOrdered = <String>[
    'rev_2009',
    'rev_2007',
    'curr_7th_1997',
    'legacy_1_6',
  ];

  static const Map<String, String> labels = <String, String>{
    'legacy_1_6': '1차-6차 포괄',
    'curr_7th_1997': '7차 (1997)',
    'rev_2007': '2007 개정',
    'rev_2009': '2009 개정',
    'rev_2015': '2015 개정',
    'rev_2022': '2022 개정',
  };

  final bool allSelected;
  final bool latestSelected;
  final bool previousSelected;
  final Set<String> legacyCodes;

  factory ProblemBankCurriculumFilter.defaults() =>
      const ProblemBankCurriculumFilter();

  bool get legacyGroupSelected => legacyCodes.isNotEmpty;

  String labelFor(String code) => labels[code] ?? code;

  String get latestLabel => labelFor(latestCode);

  String get previousLabel => labelFor(previousCode);

  String legacyGroupLabel() {
    if (legacyCodes.isEmpty) return '이전 교육과정';
    final names = legacyCodesOrdered
        .where(legacyCodes.contains)
        .map(labelFor)
        .toList(growable: false);
    return names.join(', ');
  }

  /// DB 조회용 코드 목록. 빈 목록이면 교육과정 필터 없음(전체).
  List<String> effectiveCodes() {
    if (allSelected) return const <String>[];
    final out = <String>[];
    if (latestSelected) out.add(latestCode);
    if (previousSelected) out.add(previousCode);
    for (final code in legacyCodesOrdered) {
      if (legacyCodes.contains(code)) out.add(code);
    }
    return out;
  }

  /// 단일 코드가 필요한 기존 로직용(내신 연결 등).
  String primaryCode() {
    if (allSelected) return latestCode;
    if (latestSelected) return latestCode;
    if (previousSelected) return previousCode;
    if (legacyCodes.isNotEmpty) {
      for (final code in legacyCodesOrdered) {
        if (legacyCodes.contains(code)) return code;
      }
    }
    return latestCode;
  }

  bool includesCode(String code) {
    if (allSelected) return true;
    if (code == latestCode) return latestSelected;
    if (code == previousCode) return previousSelected;
    return legacyCodes.contains(code);
  }

  bool get includesRev2015 =>
      allSelected || previousSelected || legacyCodes.contains(previousCode);

  ProblemBankCurriculumFilter copyWith({
    bool? allSelected,
    bool? latestSelected,
    bool? previousSelected,
    Set<String>? legacyCodes,
  }) {
    return ProblemBankCurriculumFilter(
      allSelected: allSelected ?? this.allSelected,
      latestSelected: latestSelected ?? this.latestSelected,
      previousSelected: previousSelected ?? this.previousSelected,
      legacyCodes: legacyCodes ?? this.legacyCodes,
    );
  }

  /// 최소 1개는 선택되도록 보정.
  ProblemBankCurriculumFilter normalized() {
    if (allSelected) {
      return copyWith(
        latestSelected: false,
        previousSelected: false,
        legacyCodes: const <String>{},
      );
    }
    if (latestSelected || previousSelected || legacyCodes.isNotEmpty) {
      return this;
    }
    return copyWith(latestSelected: true);
  }

  String scopeKeySegment() {
    if (allSelected) return 'all';
    final codes = effectiveCodes();
    if (codes.isEmpty) return 'all';
    return codes.join(',');
  }
}
