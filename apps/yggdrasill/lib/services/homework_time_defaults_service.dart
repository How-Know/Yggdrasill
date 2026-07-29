import 'package:supabase_flutter/supabase_flutter.dart';

import 'tenant_service.dart';
import 'textbook_concept_units.dart';

/// 과제 권장 소요시간 계산용 단가 저장소 (`homework_time_defaults`).
///
/// 권장시간은 마감이 아니라 페이스 지표다. 완료 조건은 항상 범위(문항)이며,
/// 이 값은 "이 정도면 끝날 분량"을 시간으로 보여주는 용도로만 쓴다.
///
/// 단가는 (시리즈, 과정, 카테고리)별 초 단위.
/// 시리즈/과정의 빈 문자열은 공통 기본이다.
/// 공통 카테고리 키:
///   * `item`          : 분류 없는 문항 1개
///   * `page`          : 문항수를 모를 때 페이지 1쪽
///   * `item_overhead` : 문항 간 전환 오버헤드 (문항당 가산)
///   * `task_overhead` : 하위과제 1개당 오버헤드
class HomeworkTimeDefaultsService {
  HomeworkTimeDefaultsService._();

  static final HomeworkTimeDefaultsService instance =
      HomeworkTimeDefaultsService._();

  /// 초기 α. 그룹 과제 합계에서는 여러 하위과제에 포함된 α를 한 번만 센다.
  static const int initialAlphaMinutes = 10;

  static const String categoryItem = 'item';
  static const String categoryPage = 'page';
  static const String categoryItemOverhead = 'item_overhead';
  static const String categoryTaskOverhead = 'task_overhead';

  Map<String, int>? _rates;
  DateTime? _loadedAt;

  bool get hasAnyRates => (_rates?.isNotEmpty ?? false);

  /// DB 마이그레이션/RLS/일시 네트워크 오류가 있어도 이미 확정한 초기 단가는
  /// 계속 적용한다. DB 값은 이 기본값 위에 덮어써서 학원별 조정을 허용한다.
  static Map<String, int> _builtInRates() {
    final out = <String, int>{};

    void add(String series, String level, String category, int seconds) {
      out[_rateKey(series, level, category)] = seconds;
    }

    add('', '', categoryTaskOverhead, initialAlphaMinutes * 60);

    add('gaeyu', 'middle', 'concept_check', 30);
    for (final category in const [
      'essential_problem',
      'step_drill',
      'unit_drill',
      'descriptive',
      'extra_practice',
    ]) {
      add('gaeyu', 'middle', category, 120);
    }

    add('wonri', 'high', '개념원리 익히기', 60);
    add('wonri', 'high', '필수유형', 120);
    add('wonri', 'high', '확인 체크', 120);
    add('wonri', 'high', '연습문제', 120);
    add('wonri', 'high', '실력 UP', 300);
    add('wonri', 'high', '특강', 120);

    add('ssen', 'middle', 'A', 20);
    add('ssen', 'middle', 'B', 90);
    add('ssen', 'middle', 'C', 300);
    add('ssen', 'high', 'A', 30);
    add('ssen', 'high', 'B', 120);
    add('ssen', 'high', 'C', 360);

    add('rpm', 'middle', 'A', 20);
    add('rpm', 'middle', 'B', 90);
    add('rpm', 'middle', 'C', 90);
    add('rpm', 'middle', '실력 UP', 300);
    add('rpm', 'high', 'A', 30);
    add('rpm', 'high', 'B', 120);
    add('rpm', 'high', 'C', 120);
    add('rpm', 'high', '실력 UP', 360);
    return out;
  }

  static String _rateKey(
    String seriesKey,
    String schoolLevelKey,
    String categoryKey,
  ) =>
      '${seriesKey.trim().toLowerCase()}|'
      '${schoolLevelKey.trim().toLowerCase()}|${categoryKey.trim()}';

  Future<void> ensureLoaded({bool force = false}) async {
    if (!force &&
        _rates != null &&
        _loadedAt != null &&
        DateTime.now().difference(_loadedAt!) < const Duration(minutes: 10)) {
      return;
    }
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final rows = await Supabase.instance.client
          .from('homework_time_defaults')
          .select(
            'series_key,school_level_key,category_key,seconds_per_unit',
          )
          .eq('academy_id', academyId);
      final next = _builtInRates();
      for (final raw in (rows as List<dynamic>)) {
        if (raw is! Map) continue;
        final series = '${raw['series_key'] ?? ''}'.trim().toLowerCase();
        final schoolLevel =
            '${raw['school_level_key'] ?? ''}'.trim().toLowerCase();
        final category = '${raw['category_key'] ?? ''}'.trim();
        final seconds = raw['seconds_per_unit'];
        final value = seconds is num ? seconds.toInt() : null;
        if (category.isEmpty || value == null || value < 0) continue;
        next[_rateKey(series, schoolLevel, category)] = value;
      }
      _rates = next;
      _loadedAt = DateTime.now();
    } catch (_) {
      // 초기 단가는 앱에도 포함해 DB 적용 전/일시 오류에도 권장시간을 계산한다.
      _rates = _builtInRates();
      _loadedAt = DateTime.now();
    }
  }

  int? _rawRate(
    String seriesKey,
    String schoolLevelKey,
    String categoryKey,
  ) =>
      _rates?[_rateKey(seriesKey, schoolLevelKey, categoryKey)];

  /// 시리즈+과정 → 시리즈 공통 → 전역 과정 → 완전 공통 순으로 조회한다.
  int? _specificRate(
    String seriesKey,
    String schoolLevelKey,
    String categoryKey,
  ) =>
      _rawRate(seriesKey, schoolLevelKey, categoryKey) ??
      _rawRate(seriesKey, '', categoryKey) ??
      _rawRate('', schoolLevelKey, categoryKey) ??
      _rawRate('', '', categoryKey);

  int? _itemRateFor(
    String seriesKey,
    String schoolLevelKey,
    String categoryKey,
  ) {
    if (categoryKey.isNotEmpty) {
      final exact = _specificRate(seriesKey, schoolLevelKey, categoryKey);
      if (exact != null) return exact;
    }
    return _specificRate(seriesKey, schoolLevelKey, categoryItem);
  }

  int _overheadRate(
    String seriesKey,
    String schoolLevelKey,
    String categoryKey,
  ) =>
      _specificRate(seriesKey, schoolLevelKey, categoryKey) ?? 0;

  /// 교재 grade_label 을 권장시간 단가의 과정 키로 정규화한다.
  ///
  /// 중등 과정은 1-1~3-2, 고등 과정은 공통수학/대수/미적분/확통/기하 등으로
  /// 저장되는 현재 교재 과정 규칙을 따른다.
  static String schoolLevelKeyForGradeLabel(String gradeLabel) {
    final compact =
        gradeLabel.trim().replaceAll(RegExp(r'\s+'), '').toLowerCase();
    if (compact.isEmpty) return '';
    if (compact.contains('고등') ||
        compact.startsWith('고1') ||
        compact.startsWith('고2') ||
        compact.startsWith('고3') ||
        compact.contains('공통수학') ||
        compact.contains('수학(상)') ||
        compact.contains('수학상') ||
        compact.contains('수학(하)') ||
        compact.contains('수학하') ||
        compact == '수학1' ||
        compact == '수학2' ||
        compact.contains('수학i') ||
        compact.contains('수학ⅰ') ||
        compact.contains('수학ⅱ') ||
        compact.contains('대수') ||
        compact.contains('미적분') ||
        compact.contains('확률과통계') ||
        compact == '확통' ||
        compact.contains('기하')) {
      return 'high';
    }
    if (compact.contains('중등') ||
        compact.startsWith('중1') ||
        compact.startsWith('중2') ||
        compact.startsWith('중3') ||
        RegExp(r'^[123]-[12]$').hasMatch(compact)) {
      return 'middle';
    }
    return '';
  }

  /// 시리즈별 문항 분류 키.
  ///
  /// * 쎈·RPM 계열: 난이도 라벨(A/B/C), 서술형/실력 UP 은 별도 키.
  /// * 개념원리: section 기반 카테고리 (개념원리 익히기/필수유형/…).
  /// * 그 외: '' (분류 없음 → item 단가).
  static String categoryKeyFor({
    required String seriesKey,
    required String label,
    required String section,
    required bool isWonri,
    String subKey = '',
  }) {
    final series = seriesKey.trim().toLowerCase();
    if (series == 'gaeyu') {
      const categories = {
        'concept_check',
        'essential_problem',
        'step_drill',
        'unit_drill',
        'descriptive',
        'extra_practice',
      };
      final normalizedSection = section.trim().toLowerCase();
      if (categories.contains(normalizedSection)) return normalizedSection;
    }
    if (isWonri || series == 'wonri') {
      final compactLabel = label.replaceAll(RegExp(r'\s+'), '').toUpperCase();
      if (section.trim() == 'exercise' &&
          (compactLabel == '실력' || compactLabel.contains('실력UP'))) {
        return '실력 UP';
      }
      final bySection = kWonriTypeNameBySection[section.trim()];
      if (bySection != null) return bySection;
      final trimmed = label.trim();
      return trimmed.isEmpty ? '' : trimmed;
    }
    final special = problemBookSpecialSectionTitle(label);
    // 현재 초기값에서 별도 단가를 둔 특수 구간은 RPM의 실력 UP뿐이다.
    // 대표 문제/서술형은 사용자가 지정한 해당 A/B/C 단계 단가를 그대로 쓴다.
    if (series == 'rpm' && special == '실력 UP') return '실력 UP';
    if (series == 'ssen' || series == 'rpm') {
      final normalizedSubKey = subKey.trim().toUpperCase();
      if (const {'A', 'B', 'C'}.contains(normalizedSubKey)) {
        return normalizedSubKey;
      }
      const bySection = {
        'basic_drill': 'A',
        'type_practice': 'B',
        'mastery': 'C',
      };
      final sectionKey = bySection[section.trim().toLowerCase()];
      if (sectionKey != null) return sectionKey;
    }
    final compactNoSpace = label.trim().replaceAll(RegExp(r'\s+'), '');
    if (compactNoSpace == '대표문제') return '대표 문제';
    final compact = label.trim().toUpperCase();
    if (compact == 'A' || compact == 'B' || compact == 'C') return compact;
    return '';
  }

  /// 권장 소요시간(초). 단가가 하나도 없으면 null (기능 꺼짐).
  ///
  /// [categoryCounts]: 분류별 문항수. [uncategorizedCount]: 분류 없는 문항수.
  /// 문항 정보가 전혀 없으면 [pageCount]로 페이지 단가를 쓴다.
  int? estimateSeconds({
    required String seriesKey,
    String schoolLevelKey = '',
    Map<String, int> categoryCounts = const <String, int>{},
    int uncategorizedCount = 0,
    int? pageCount,
    int taskCount = 1,
  }) {
    final rates = _rates;
    if (rates == null || rates.isEmpty) return null;
    final series = seriesKey.trim().toLowerCase();
    final schoolLevel = schoolLevelKey.trim().toLowerCase();

    var total = 0;
    var itemTotal = 0;
    var priced = false;

    void addItems(String category, int count) {
      if (count <= 0) return;
      final rate = _itemRateFor(series, schoolLevel, category);
      if (rate == null) return;
      total += rate * count;
      itemTotal += count;
      priced = true;
    }

    categoryCounts.forEach(addItems);
    addItems('', uncategorizedCount);

    if (!priced && pageCount != null && pageCount > 0) {
      final pageRate = _specificRate(series, schoolLevel, categoryPage);
      if (pageRate != null) {
        total += pageRate * pageCount;
        priced = true;
      }
    }
    if (!priced) return null;

    total +=
        _overheadRate(series, schoolLevel, categoryItemOverhead) * itemTotal;
    total += _overheadRate(series, schoolLevel, categoryTaskOverhead) *
        (taskCount <= 0 ? 1 : taskCount);
    return total;
  }

  /// 권장 소요시간(분, 올림·최소 1분). 계산 불가면 null.
  int? estimateMinutes({
    required String seriesKey,
    String schoolLevelKey = '',
    Map<String, int> categoryCounts = const <String, int>{},
    int uncategorizedCount = 0,
    int? pageCount,
    int taskCount = 1,
  }) {
    final seconds = estimateSeconds(
      seriesKey: seriesKey,
      schoolLevelKey: schoolLevelKey,
      categoryCounts: categoryCounts,
      uncategorizedCount: uncategorizedCount,
      pageCount: pageCount,
      taskCount: taskCount,
    );
    if (seconds == null || seconds <= 0) return null;
    final minutes = (seconds + 59) ~/ 60;
    return minutes < 1 ? 1 : minutes;
  }
}
