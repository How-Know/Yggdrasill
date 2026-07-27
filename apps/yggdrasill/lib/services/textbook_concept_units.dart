/// 개념서(개념원리) 단원트리 표시 규칙 공유 헬퍼.
///
/// 개념서 payload 는 `middles[].smalls` 에 문항 카테고리(A~D:
/// 개념원리 익히기 / 필수유형 / 확인 체크 / 연습문제)를 담고, 사람이 읽는
/// 실제 소단원명(거듭제곱과 거듭제곱근, 지수의 확장 …)은 `middles[].sub_units`
/// 에 따로 담는다. 학습앱 단원트리는 "문항 카테고리" 가 아니라 "실제 소단원"
/// 을 보여줘야 하므로, sub_units 가 있으면 그것을, 없으면 smalls 를 소단원으로
/// 쓴다. (문제집 쎈/RPM 은 sub_units 가 없어 smalls 를 그대로 사용한다.)
///
/// 문항(크롭)은 sub_key(A~D)로 저장돼 있어 소단원과 직접 대응되지 않으므로,
/// display_page(교과서 표시 페이지) 가 소단원 [start_page, end_page] 범위에
/// 들어가는지로 매핑한다. sub_units 에는 각 소단원의 시작/끝 페이지가 저장돼
/// 있다.
library;

class ConceptDisplaySubUnit {
  const ConceptDisplaySubUnit({
    required this.order,
    required this.subKey,
    required this.name,
    required this.startPage,
    required this.endPage,
    required this.isExercise,
    required this.raw,
  });

  final int order;

  /// 합성/원본 키. sub_units 는 'U<order>', smalls 는 원본 sub_key(A~D).
  final String subKey;
  final String name;
  final int? startPage;
  final int? endPage;
  final bool isExercise;

  /// 원본 맵 (answer_start_page 등 부가 필드 접근용).
  final Map<String, dynamic> raw;
}

int? conceptToInt(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

Map<String, dynamic> _asMap(dynamic value) {
  if (value is Map) {
    return value.map((k, v) => MapEntry('$k', v));
  }
  return const <String, dynamic>{};
}

/// 개념서 여부 판별: 중단원에 실제 소단원 목록(sub_units)이 있으면 개념서.
bool midHasSubUnits(Map<dynamic, dynamic> mid) {
  final su = mid['sub_units'];
  return su is List && su.isNotEmpty;
}

/// 학습앱 단원트리에 표시할 소단원 목록.
/// - 개념서(개념원리): `sub_units` 를 소단원으로.
/// - 그 외(쎈/RPM): `smalls` 를 그대로.
List<ConceptDisplaySubUnit> displaySubUnitsForMid(Map<dynamic, dynamic> mid) {
  final out = <ConceptDisplaySubUnit>[];
  if (midHasSubUnits(mid)) {
    final raw = mid['sub_units'] as List;
    for (var i = 0; i < raw.length; i += 1) {
      final m = _asMap(raw[i]);
      if (m.isEmpty) continue;
      final order = conceptToInt(m['order_index']) ?? i;
      final name = '${m['name'] ?? ''}'.trim();
      out.add(
        ConceptDisplaySubUnit(
          order: order,
          subKey: 'U$order',
          name: name.isEmpty ? '소단원' : name,
          startPage: conceptToInt(m['start_page']),
          endPage: conceptToInt(m['end_page']),
          isExercise: m['is_exercise'] == true,
          raw: m,
        ),
      );
    }
    return out;
  }
  final smalls = mid['smalls'];
  if (smalls is List) {
    for (var i = 0; i < smalls.length; i += 1) {
      final m = _asMap(smalls[i]);
      if (m.isEmpty) continue;
      final order = conceptToInt(m['order_index']) ?? i;
      final name = '${m['name'] ?? ''}'.trim();
      out.add(
        ConceptDisplaySubUnit(
          order: order,
          subKey: '${m['sub_key'] ?? ''}'.trim(),
          name: name.isEmpty ? '소단원' : name,
          startPage: conceptToInt(m['start_page']),
          endPage: conceptToInt(m['end_page']),
          isExercise: m['is_exercise'] == true,
          raw: m,
        ),
      );
    }
  }
  return out;
}

/// 페이지(교과서 표시 페이지)가 속한 소단원의 인덱스를 찾는다. 없으면 null.
/// 범위가 겹치지 않는다고 가정하고 첫 매칭을 반환한다.
int? conceptSubUnitIndexForPage(
  List<ConceptDisplaySubUnit> subUnits,
  int page,
) {
  if (page <= 0) return null;
  for (var i = 0; i < subUnits.length; i += 1) {
    final s = subUnits[i];
    final start = s.startPage;
    final end = s.endPage;
    if (start == null) continue;
    final hi = end ?? start;
    if (page >= start && page <= hi) return i;
  }
  return null;
}

/// 개념원리 section / sub_key → 기본 유형명.
const Map<String, String> kWonriTypeNameBySection = {
  'concept_drill': '개념원리 익히기',
  'type_example': '필수유형',
  'check': '확인 체크',
  'exercise': '연습문제',
  'special_lecture': '특강',
};

const Map<String, String> kWonriTypeNameBySubKey = {
  'A': '개념원리 익히기',
  'B': '필수유형',
  'C': '확인 체크',
  'D': '연습문제',
  'E': '특강',
};

/// 개념원리 문항 표시용 유형명.
///
/// 우선순위: content_group(type) → item_name → section → sub_key.
/// 필수유형은 content_group 이 있으면 `01 제목`처럼 세부 유형으로,
/// 연습문제는 item_name(STEP1/실력 UP 등)으로 나뉜다.
String wonriTypeDisplayName({
  required String section,
  required String subKey,
  required String itemName,
  String typeGroupKind = '',
  String typeGroupLabel = '',
  String typeGroupTitle = '',
}) {
  final kind = typeGroupKind.trim().toLowerCase();
  final groupLabel = typeGroupLabel.trim();
  final groupTitle = typeGroupTitle.trim();
  if (kind == 'type' && groupLabel.isNotEmpty) {
    return groupTitle.isEmpty ? groupLabel : '$groupLabel $groupTitle';
  }

  final normalizedItem = normalizeWonriItemName(itemName);
  if (normalizedItem.isNotEmpty) return normalizedItem;

  final bySection = kWonriTypeNameBySection[section.trim()] ?? '';
  if (bySection.isNotEmpty) return bySection;

  final bySub = kWonriTypeNameBySubKey[subKey.trim().toUpperCase()] ?? '';
  if (bySub.isNotEmpty) return bySub;

  return '';
}

/// 탐색기/필터용 유형 그룹 키 (`label|title` 형식, [TbExItem.typeGroupTitleOf] 호환).
String wonriTypeGroupKey({
  required String section,
  required String subKey,
  required String itemName,
  String typeGroupKind = '',
  String typeGroupLabel = '',
  String typeGroupTitle = '',
}) {
  final kind = typeGroupKind.trim().toLowerCase();
  final groupLabel = typeGroupLabel.trim();
  final groupTitle = typeGroupTitle.trim();
  if (kind == 'type' && groupLabel.isNotEmpty) {
    return '$groupLabel|$groupTitle';
  }
  final name = wonriTypeDisplayName(
    section: section,
    subKey: subKey,
    itemName: itemName,
    typeGroupKind: typeGroupKind,
    typeGroupLabel: typeGroupLabel,
    typeGroupTitle: typeGroupTitle,
  );
  if (name.isEmpty) return '유형 미지정|';
  return '$name|';
}

String normalizeWonriItemName(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return '';
  switch (text) {
    case '확인체크':
      return '확인 체크';
    case '필수':
      return '필수유형';
    case '실력':
    case '실력UP':
      return '실력 UP';
    case '수능기출':
      return '수능 기출';
    case '평가원기출':
      return '평가원 기출';
    case '교육청기출':
      return '교육청 기출';
    default:
      return text;
  }
}

/// 문제집(RPM 등) C단계 특수 섹션명. 해당 없으면 null.
String? problemBookSpecialSectionTitle(String rawLabel) {
  final label = rawLabel.trim();
  if (label.isEmpty) return null;
  final compact = label.replaceAll(RegExp(r'\s+'), '');
  if (compact.contains('서술')) return '서술형 주관식';
  if (compact.contains('실력')) return '실력 UP';
  return null;
}
