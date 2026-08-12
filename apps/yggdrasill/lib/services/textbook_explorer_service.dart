import '../screens/learning/models/problem_bank_export_models.dart';
import 'data_manager.dart';
import 'learning_problem_bank_service.dart';
import 'tenant_service.dart';
import 'textbook_concept_units.dart';
import '../utils/textbook_problem_source_order.dart';

/// 문항 응답 유형(객관식/주관식/서술형) 표시용.
enum TbAnswerKind { objective, subjective, essay, unknown }

extension TbAnswerKindLabel on TbAnswerKind {
  String get label {
    switch (this) {
      case TbAnswerKind.objective:
        return '객관식';
      case TbAnswerKind.subjective:
        return '주관식';
      case TbAnswerKind.essay:
        return '서술형';
      case TbAnswerKind.unknown:
        return '';
    }
  }
}

/// 교재 단원/문항 탐색 화면에서 사용하는 단일 문항(크롭) 정보.
class TbExItem {
  const TbExItem({
    required this.cropId,
    required this.questionUid,
    required this.problemNumber,
    required this.difficultyLabel,
    required this.answerKind,
    required this.section,
    required this.isWonri,
    required this.typeGroupKind,
    required this.typeGroupLabel,
    required this.typeGroupTitle,
    required this.rawPage,
    required this.displayPage,
    required this.bigOrder,
    required this.midOrder,
    required this.subKey,
    this.subIndex = 0,
    required this.isSetHeader,
    required this.setFrom,
    required this.setTo,
    required this.xmin,
    required this.ymin,
    required this.xmax,
    required this.ymax,
    this.numberXmin,
    this.numberYmin,
    this.numberXmax,
    this.numberYmax,
    required this.sortOrder,
  });

  final String cropId;
  final String questionUid;
  final String problemNumber;
  final String difficultyLabel;
  final TbAnswerKind answerKind;
  final String section;
  final bool isWonri;
  final String typeGroupKind;
  final String typeGroupLabel;
  final String typeGroupTitle;
  final int rawPage;
  final int? displayPage;
  final int bigOrder;
  final int midOrder;
  final String subKey;
  final int subIndex;
  final bool isSetHeader;
  final int? setFrom;
  final int? setTo;

  /// 0~1 정규화 좌표 (페이지 좌상단 기준).
  final double xmin;
  final double ymin;
  final double xmax;
  final double ymax;

  /// VLM `bbox_1k` — 원본 PDF에 인쇄된 문항번호 영역 [ymin,xmin,ymax,xmax].
  final double? numberXmin;
  final double? numberYmin;
  final double? numberXmax;
  final double? numberYmax;
  final int sortOrder;

  bool get hasUid => questionUid.trim().isNotEmpty;
  bool get hasRegion => xmax > xmin && ymax > ymin;
  bool get hasNumberRegion {
    final nx0 = numberXmin;
    final ny0 = numberYmin;
    final nx1 = numberXmax;
    final ny1 = numberYmax;
    if (nx0 == null || ny0 == null || nx1 == null || ny1 == null) {
      return false;
    }
    return nx1 > nx0 && ny1 > ny0;
  }

  /// 하이라이트/선택용 안정 키. UID가 없으면 페이지/순서 기반 합성 키.
  String get selKey => hasUid ? questionUid : 'r:$rawPage:$sortOrder';

  /// 유형 그룹 키 (문제은행 탭과 동일 규칙).
  String get typeGroupKey {
    if (typeGroupKind == 'type' && typeGroupLabel.isNotEmpty) {
      return '$typeGroupLabel|$typeGroupTitle';
    }
    if (isWonri) {
      return wonriTypeGroupKey(
        section: section,
        subKey: subKey,
        itemName: difficultyLabel,
        typeGroupKind: typeGroupKind,
        typeGroupLabel: typeGroupLabel,
        typeGroupTitle: typeGroupTitle,
      );
    }
    // RPM(및 유사 문제집) C단계 서술형/실력 UP — label 을 유형 키로 쓴다.
    final special = problemBookSpecialSectionTitle(difficultyLabel);
    if (special != null) return '$special|';
    return '유형 미지정|';
  }

  String get displayNumber {
    if (isSetHeader) {
      final from = setFrom?.toString() ?? '?';
      final to = setTo?.toString() ?? '?';
      return '$from~$to';
    }
    return problemNumber;
  }

  TbExItem copyWith({
    String? questionUid,
    TbAnswerKind? answerKind,
  }) {
    return TbExItem(
      cropId: cropId,
      questionUid: questionUid ?? this.questionUid,
      problemNumber: problemNumber,
      difficultyLabel: difficultyLabel,
      answerKind: answerKind ?? this.answerKind,
      section: section,
      isWonri: isWonri,
      typeGroupKind: typeGroupKind,
      typeGroupLabel: typeGroupLabel,
      typeGroupTitle: typeGroupTitle,
      rawPage: rawPage,
      displayPage: displayPage,
      bigOrder: bigOrder,
      midOrder: midOrder,
      subKey: subKey,
      subIndex: subIndex,
      isSetHeader: isSetHeader,
      setFrom: setFrom,
      setTo: setTo,
      xmin: xmin,
      ymin: ymin,
      xmax: xmax,
      ymax: ymax,
      numberXmin: numberXmin,
      numberYmin: numberYmin,
      numberXmax: numberXmax,
      numberYmax: numberYmax,
      sortOrder: sortOrder,
    );
  }

  static String typeGroupTitleOf(String key) {
    final parts = key.split('|');
    final label = parts.isNotEmpty ? parts.first.trim() : '';
    final title = parts.length > 1 ? parts.sublist(1).join('|').trim() : '';
    if (label.isEmpty || label == '유형 미지정') return '유형 미지정';
    return title.isEmpty ? label : '$label $title';
  }
}

class TbExPage {
  TbExPage({
    required this.rawPage,
    required this.displayPage,
    required this.items,
  });

  final int rawPage;
  final int? displayPage;
  final List<TbExItem> items;

  String get label {
    final shown = displayPage ?? rawPage;
    return '$shown쪽';
  }

  int get numberedQuestionCount => items
      .where((e) => !e.isSetHeader && e.problemNumber.trim().isNotEmpty)
      .length;

  /// 메타데이터 범위에는 있지만 탐지 문항이 없는 교재 개념 페이지.
  bool get isConceptPage => items.isEmpty;
}

class TbExSmallUnit {
  TbExSmallUnit({
    required this.key,
    required this.name,
    required this.order,
    required this.items,
    required this.pages,
    Set<int>? metadataPageNumbers,
  }) : metadataPageNumbers = metadataPageNumbers ?? const <int>{};

  final String key;
  final String name;
  final int order;
  final List<TbExItem> items;
  final List<TbExPage> pages;

  /// 메타데이터 start/end·page_counts에 포함된 전체 페이지(개념 페이지 포함).
  final Set<int> metadataPageNumbers;

  int get numberedQuestionCount => items
      .where((e) => !e.isSetHeader && e.problemNumber.trim().isNotEmpty)
      .length;
}

class TbExMidUnit {
  TbExMidUnit({
    required this.name,
    required this.order,
    required this.smalls,
  });

  final String name;
  final int order;
  final List<TbExSmallUnit> smalls;
}

class TbExBigUnit {
  TbExBigUnit({
    required this.name,
    required this.order,
    required this.mids,
  });

  final String name;
  final int order;
  final List<TbExMidUnit> mids;
}

class TbExData {
  const TbExData({
    required this.units,
    required this.itemsByPage,
    required this.totalPages,
    required this.totalQuestions,
  });

  final List<TbExBigUnit> units;
  final Map<int, List<TbExItem>> itemsByPage;
  final int totalPages;
  final int totalQuestions;

  bool get hasQuestions => totalQuestions > 0;

  static const TbExData empty = TbExData(
    units: <TbExBigUnit>[],
    itemsByPage: <int, List<TbExItem>>{},
    totalPages: 0,
    totalQuestions: 0,
  );
}

/// 교재 단원/문항 탐색 데이터를 한 번에 로드/조립한다.
class TextbookExplorerService {
  TextbookExplorerService._();
  static final TextbookExplorerService instance = TextbookExplorerService._();

  final LearningProblemBankService _pbService = LearningProblemBankService();
  final Map<String, TbExData> _dataCache = <String, TbExData>{};
  final Map<String, dynamic> _payloadCache = <String, dynamic>{};
  final Map<String, List<TbExItem>> _flatItemsCache =
      <String, List<TbExItem>>{};
  final Map<String, Map<String, _ConceptRange>> _specialRangeCache =
      <String, Map<String, _ConceptRange>>{};

  // v4: 서버의 정규화 특강 페이지 범위를 함께 반영.
  String _cacheKey(String bookId, String gradeLabel) =>
      'v4|${bookId.trim()}|${gradeLabel.trim()}';

  /// 캐시된 payload 의 series 키 (`ssen` / `rpm` / `wonri` …). 없으면 빈 문자열.
  String seriesKeyOf({
    required String bookId,
    required String gradeLabel,
  }) {
    final payload = _payloadCache[_cacheKey(bookId, gradeLabel)];
    if (payload is Map) {
      return '${payload['series'] ?? ''}'.trim().toLowerCase();
    }
    return '';
  }

  /// 단원트리 표시용 최소 로드(메타+크롭 병렬). PB 보강은 [enrich]에서.
  Future<TbExData> loadCore({
    required String bookId,
    required String gradeLabel,
  }) async {
    final safeBookId = bookId.trim();
    final safeGrade = gradeLabel.trim();
    if (safeBookId.isEmpty) return TbExData.empty;
    final key = _cacheKey(safeBookId, safeGrade);
    final cached = _dataCache[key];
    if (cached != null) return cached;

    final results = await Future.wait<Object?>([
      DataManager.instance.loadTextbookMetadataPayload(
        bookId: safeBookId,
        gradeLabel: safeGrade,
      ),
      DataManager.instance.loadTextbookProblemRegions(
        bookId: safeBookId,
        gradeLabel: safeGrade.isEmpty ? null : safeGrade,
      ),
      DataManager.instance.loadTextbookSpecialUnits(
        bookId: safeBookId,
        gradeLabel: safeGrade,
      ),
    ]);
    final payloadRow = results[0] as Map<String, dynamic>?;
    final cropRows = (results[1] as List<Map<String, dynamic>>?) ??
        const <Map<String, dynamic>>[];
    final specialRows = (results[2] as List<Map<String, dynamic>>?) ??
        const <Map<String, dynamic>>[];
    final payload = payloadRow?['payload'];
    final payloadMap =
        payload is Map ? _asMap(payload) : const <String, dynamic>{};
    final isWonri =
        '${payloadMap['series'] ?? ''}'.trim().toLowerCase() == 'wonri';

    final items = <TbExItem>[];
    var order = 0;
    for (final row in cropRows) {
      final item = _itemFromRow(row, order, isWonri: isWonri);
      if (item == null) continue;
      items.add(item);
      order += 1;
    }

    final specialRanges = _specialRangesFromRows(specialRows);
    final data = _assembleData(
      payload: payload,
      items: items,
      specialRanges: specialRanges,
    );
    _payloadCache[key] = payload;
    _flatItemsCache[key] = items;
    _specialRangeCache[key] = specialRanges;
    _dataCache[key] = data;
    return data;
  }

  /// PB 링크·응답유형 보강. 실패해도 core 트리는 유지.
  Future<TbExData> enrich({
    required String bookId,
    required String gradeLabel,
  }) async {
    final safeBookId = bookId.trim();
    final safeGrade = gradeLabel.trim();
    if (safeBookId.isEmpty) return TbExData.empty;
    final key = _cacheKey(safeBookId, safeGrade);
    final baseItems = _flatItemsCache[key];
    final payload = _payloadCache[key];
    final specialRanges =
        _specialRangeCache[key] ?? const <String, _ConceptRange>{};
    if (baseItems == null) {
      return loadCore(bookId: safeBookId, gradeLabel: safeGrade);
    }

    final resolvedQuestionUidByCropId = <String, String>{};
    final resolvedQuestionUidByLocation = <String, String>{};
    try {
      final academyId = await TenantService.instance.getActiveAcademyId();
      if (academyId != null && academyId.trim().isNotEmpty) {
        final links = await _pbService.loadTextbookQuestionLinkRows(
          academyId: academyId,
          bookId: safeBookId,
          gradeLabel: safeGrade,
        );
        for (final row in links) {
          final meta = _asMap(row['meta']);
          final cropPage = _asMap(meta['textbook_crop_page']);
          final scope = _asMap(meta['textbook_scope'] ?? meta['textbookScope']);
          final uid = '${row['question_uid'] ?? row['id'] ?? ''}'.trim();
          if (uid.isEmpty) continue;
          final cropId = '${cropPage['crop_id'] ?? ''}'.trim();
          if (cropId.isNotEmpty) {
            resolvedQuestionUidByCropId[cropId] = uid;
          }
          final bigOrder = _toInt(scope['big_order'] ?? scope['bigOrder']);
          final midOrder = _toInt(scope['mid_order'] ?? scope['midOrder']);
          final subKey = '${scope['sub_key'] ?? scope['subKey'] ?? ''}'.trim();
          final rawPage = _toInt(cropPage['raw_page']);
          final problemNumber = '${row['question_number'] ?? ''}'.trim();
          if (bigOrder != null &&
              midOrder != null &&
              subKey.isNotEmpty &&
              rawPage != null &&
              problemNumber.isNotEmpty) {
            resolvedQuestionUidByLocation[
                '$bigOrder|$midOrder|$subKey|$rawPage|$problemNumber'] = uid;
          }
        }
      }
    } catch (_) {
      // 직접 연결된 pb_question_uid가 있으면 기존 경로로 계속 동작한다.
    }

    final linkedItems = baseItems.map((item) {
      if (item.questionUid.trim().isNotEmpty) return item;
      final byCrop = resolvedQuestionUidByCropId[item.cropId];
      final byLocation = resolvedQuestionUidByLocation[
          '${item.bigOrder}|${item.midOrder}|${item.subKey}|'
              '${item.rawPage}|${item.problemNumber}'];
      final resolved = (byCrop ?? byLocation ?? '').trim();
      return resolved.isEmpty ? item : item.copyWith(questionUid: resolved);
    }).toList(growable: false);

    final uids = linkedItems
        .where((e) => e.hasUid)
        .map((e) => e.questionUid)
        .toSet()
        .toList(growable: false);
    final answerKindByUid = <String, TbAnswerKind>{};
    if (uids.isNotEmpty) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId();
        if (academyId != null && academyId.trim().isNotEmpty) {
          final questions = await _pbService.loadQuestionsByQuestionUids(
            academyId: academyId,
            questionUids: uids,
          );
          for (final q in questions) {
            answerKindByUid[q.stableQuestionKey] = _answerKindFor(q);
          }
        }
      } catch (_) {
        // 보강 실패는 치명적이지 않음.
      }
    }

    final resolvedItems = linkedItems
        .map(
          (e) => e.hasUid && answerKindByUid.containsKey(e.questionUid)
              ? e.copyWith(answerKind: answerKindByUid[e.questionUid])
              : e,
        )
        .toList(growable: false);

    final data = _assembleData(
      payload: payload,
      items: resolvedItems,
      specialRanges: specialRanges,
    );
    _flatItemsCache[key] = resolvedItems;
    _dataCache[key] = data;
    return data;
  }

  /// 전체 로드(코어+보강). 자원 화면 등 기존 호출부 호환.
  Future<TbExData> load({
    required String bookId,
    required String gradeLabel,
  }) async {
    await loadCore(bookId: bookId, gradeLabel: gradeLabel);
    return enrich(bookId: bookId, gradeLabel: gradeLabel);
  }

  TbExData _assembleData({
    required dynamic payload,
    required List<TbExItem> items,
    Map<String, _ConceptRange> specialRanges = const <String, _ConceptRange>{},
  }) {
    final units = _buildUnits(payload, items, specialRanges: specialRanges);
    final itemsByPage = <int, List<TbExItem>>{};
    for (final item in items) {
      if (item.rawPage <= 0) continue;
      itemsByPage.putIfAbsent(item.rawPage, () => <TbExItem>[]).add(item);
    }
    final totalPages = _computeTotalPages(payload, items);
    final numberedUids = <String>{};
    var unnumberedNoUid = 0;
    for (final item in items) {
      if (item.isSetHeader) continue;
      if (item.problemNumber.trim().isEmpty) continue;
      if (item.hasUid) {
        numberedUids.add(item.questionUid);
      } else {
        unnumberedNoUid += 1;
      }
    }
    return TbExData(
      units: units,
      itemsByPage: itemsByPage,
      totalPages: totalPages,
      totalQuestions: numberedUids.length + unnumberedNoUid,
    );
  }

  TbExItem? _itemFromRow(
    Map<String, dynamic> row,
    int sortOrder, {
    required bool isWonri,
  }) {
    final rawPage = _toInt(row['raw_page']) ?? 0;
    final region = _toIntList(row['item_region_1k']);
    final numberBbox = _toIntList(row['bbox_1k']);
    final number = '${row['problem_number'] ?? ''}'.trim();
    final isSetHeader = row['is_set_header'] == true;
    if (number.isEmpty && !isSetHeader) return null;
    double frac(List<int>? box, int index) {
      if (box == null || box.length != 4) return 0;
      return (box[index] / 1000.0).clamp(0.0, 1.0);
    }

    double? nfrac(List<int>? box, int index) {
      if (box == null || box.length != 4) return null;
      return (box[index] / 1000.0).clamp(0.0, 1.0);
    }

    final itemName = '${row['item_name'] ?? ''}'.trim();
    final rawLabel = '${row['label'] ?? ''}'.trim();
    // 개념원리는 난이도(label)가 비어 있고 문항이름(item_name)에 유형명이 있다.
    final displayLabel = isWonri
        ? (itemName.isNotEmpty ? itemName : rawLabel)
        : _normalizeDifficulty(rawLabel);
    return TbExItem(
      cropId: '${row['id'] ?? ''}'.trim(),
      questionUid: '${row['pb_question_uid'] ?? ''}'.trim(),
      problemNumber: number,
      difficultyLabel: displayLabel,
      answerKind: TbAnswerKind.unknown,
      section: '${row['section'] ?? ''}'.trim(),
      isWonri: isWonri,
      typeGroupKind: '${row['content_group_kind'] ?? ''}'.trim(),
      typeGroupLabel: '${row['content_group_label'] ?? ''}'.trim(),
      typeGroupTitle: '${row['content_group_title'] ?? ''}'.trim(),
      rawPage: rawPage,
      displayPage: _toInt(row['display_page']),
      bigOrder: _toInt(row['big_order']) ?? 0,
      midOrder: _toInt(row['mid_order']) ?? 0,
      subKey: '${row['sub_key'] ?? ''}'.trim(),
      subIndex: _toInt(row['sub_index']) ?? 0,
      isSetHeader: isSetHeader,
      setFrom: _toInt(row['set_from']),
      setTo: _toInt(row['set_to']),
      xmin: frac(region, 1),
      ymin: frac(region, 0),
      xmax: frac(region, 3),
      ymax: frac(region, 2),
      numberXmin: nfrac(numberBbox, 1),
      numberYmin: nfrac(numberBbox, 0),
      numberXmax: nfrac(numberBbox, 3),
      numberYmax: nfrac(numberBbox, 2),
      sortOrder: sortOrder,
    );
  }

  String _normalizeDifficulty(String raw) {
    final compact = raw.trim().replaceAll(RegExp(r'\s+'), '');
    if (compact == '대표문제') return '대표 문제';
    return raw.trim();
  }

  TbAnswerKind _answerKindFor(LearningProblemQuestion q) {
    final mode = originalQuestionModeOf(q);
    switch (mode) {
      case kLearningQuestionModeObjective:
        return TbAnswerKind.objective;
      case kLearningQuestionModeEssay:
        return TbAnswerKind.essay;
      case kLearningQuestionModeSubjective:
        return TbAnswerKind.subjective;
      default:
        return TbAnswerKind.unknown;
    }
  }

  List<TbExBigUnit> _buildUnits(
    dynamic payload,
    List<TbExItem> items, {
    Map<String, _ConceptRange> specialRanges = const <String, _ConceptRange>{},
  }) {
    final itemsByKey = <String, List<TbExItem>>{};
    final itemsByMid = <String, List<TbExItem>>{};
    for (final item in items) {
      final key = '${item.bigOrder}|${item.midOrder}|${item.subKey}';
      itemsByKey.putIfAbsent(key, () => <TbExItem>[]).add(item);
      final midKey = '${item.bigOrder}|${item.midOrder}';
      itemsByMid.putIfAbsent(midKey, () => <TbExItem>[]).add(item);
    }
    for (final list in itemsByKey.values) {
      list.sort(_compareItems);
    }

    final units = <TbExBigUnit>[];
    final unitMeta = _parseUnitMeta(payload);
    final usedKeys = <String>{};

    if (unitMeta.isNotEmpty) {
      for (final big in unitMeta) {
        final mids = <TbExMidUnit>[];
        for (final mid in big.mids) {
          final smalls = <TbExSmallUnit>[];
          if (mid.isConcept) {
            // 개념서: 문항을 sub_key 가 아니라 소단원(sub_units) 페이지 범위로
            // 매핑한다. 한 소단원에 개념원리 익히기/필수유형/확인 체크/연습문제
            // 문항이 페이지 기준으로 모인다.
            // 특강(E)은 payload sub_units 에 없고 소단원 1 앞에 붙는 경우가
            // 많아(예: 확통 순열과 조합 특강 → 중복순열) 별도 가상 소단원으로 복원한다.
            final midKey = '${big.order}|${mid.order}';
            final midItems = itemsByMid[midKey] ?? const <TbExItem>[];
            final buckets =
                List<List<TbExItem>>.generate(mid.smalls.length, (_) => []);
            final ranges = mid.smalls
                .map((s) => _ConceptRange(s.startPage, s.endPage))
                .toList(growable: false);
            final specialMetaIndex = mid.smalls.indexWhere(
              (small) =>
                  small.subKey.trim().toUpperCase() == 'E' ||
                  small.name.trim().contains('특강'),
            );
            final specialItems = <TbExItem>[];
            final unassigned = <TbExItem>[];
            for (final it in midItems) {
              if (_isSpecialLectureItem(it)) {
                if (specialMetaIndex >= 0) {
                  buckets[specialMetaIndex].add(it);
                } else {
                  specialItems.add(it);
                }
                continue;
              }
              final page = it.displayPage ?? it.rawPage;
              final idx = _conceptBucketForPage(ranges, page);
              if (idx != null) {
                buckets[idx].add(it);
              } else {
                unassigned.add(it);
              }
            }
            for (var si = 0; si < mid.smalls.length; si += 1) {
              final small = mid.smalls[si];
              final list = buckets[si]..sort(_compareItems);
              if (small.pageNumbers.isEmpty && list.isEmpty) continue;
              smalls.add(
                _buildSmall(
                  '${big.order}|${mid.order}|${small.subKey}',
                  small.name,
                  small.order,
                  list,
                  metadataPageNumbers: small.pageNumbers,
                  includeMetadataPages: true,
                ),
              );
            }
            if (specialMetaIndex < 0) {
              final specialUnit = _buildSpecialLectureSmall(
                bigOrder: big.order,
                midOrder: mid.order,
                mid: mid,
                specialItems: specialItems,
                unassignedItems: unassigned,
                normalizedRange: specialRanges[midKey],
              );
              if (specialUnit != null) {
                smalls.add(specialUnit);
                smalls.sort(_compareSmallsByPage);
              }
            }
            // 이 중단원의 모든 sub_key 문항을 소비 처리(leftover 방지).
            for (final entry in itemsByKey.keys) {
              if (entry.startsWith('$midKey|')) usedKeys.add(entry);
            }
          } else {
            for (final small in mid.smalls) {
              final key = '${big.order}|${mid.order}|${small.subKey}';
              final list = itemsByKey[key] ?? const <TbExItem>[];
              if (list.isEmpty) continue;
              usedKeys.add(key);
              smalls.add(
                _buildSmall(
                  key,
                  small.name,
                  small.order,
                  list,
                  metadataPageNumbers: small.pageNumbers,
                  includeMetadataPages: true,
                ),
              );
            }
          }
          if (smalls.isEmpty) continue;
          mids.add(
              TbExMidUnit(name: mid.name, order: mid.order, smalls: smalls));
        }
        if (mids.isEmpty) continue;
        units.add(TbExBigUnit(name: big.name, order: big.order, mids: mids));
      }
    }

    final leftover = <String, List<TbExItem>>{};
    for (final entry in itemsByKey.entries) {
      if (usedKeys.contains(entry.key)) continue;
      leftover[entry.key] = entry.value;
    }
    if (leftover.isNotEmpty) {
      _appendLeftoverUnits(units, leftover);
    }

    units.sort((a, b) => a.order.compareTo(b.order));
    return units;
  }

  TbExSmallUnit _buildSmall(
    String key,
    String name,
    int order,
    List<TbExItem> items, {
    Set<int> metadataPageNumbers = const <int>{},
    bool includeMetadataPages = false,
  }) {
    final byPage = <int, List<TbExItem>>{};
    final displayPageByRaw = <int, int>{};
    int? displayPageOf(int raw) {
      final fromMetadata = displayPageByRaw[raw];
      if (fromMetadata != null) return fromMetadata;
      for (final it in items) {
        if (it.rawPage == raw && it.displayPage != null) return it.displayPage;
      }
      return null;
    }

    for (final it in items) {
      if (it.rawPage <= 0) continue;
      byPage.putIfAbsent(it.rawPage, () => <TbExItem>[]).add(it);
    }
    if (includeMetadataPages) {
      TbExItem? offsetSample;
      for (final item in items) {
        if (item.displayPage == null) continue;
        offsetSample = item;
        break;
      }
      final rawOffset = offsetSample == null
          ? 0
          : offsetSample.rawPage - offsetSample.displayPage!;
      for (final displayPage in metadataPageNumbers) {
        if (displayPage <= 0) continue;
        final rawPage = displayPage + rawOffset;
        if (rawPage <= 0) continue;
        displayPageByRaw[rawPage] = displayPage;
        byPage.putIfAbsent(rawPage, () => <TbExItem>[]);
      }
    }
    final pageKeys = byPage.keys.toList()..sort();
    final pages = <TbExPage>[
      for (final raw in pageKeys)
        TbExPage(
          rawPage: raw,
          displayPage: displayPageOf(raw),
          items: byPage[raw]!,
        ),
    ];
    return TbExSmallUnit(
      key: key,
      name: name,
      order: order,
      items: items,
      pages: pages,
      metadataPageNumbers: metadataPageNumbers,
    );
  }

  void _appendLeftoverUnits(
    List<TbExBigUnit> units,
    Map<String, List<TbExItem>> leftover,
  ) {
    final byBig = <int, Map<int, List<TbExSmallUnit>>>{};
    final bigNames = <int, String>{};
    final midNames = <String, String>{};

    for (final entry in leftover.entries) {
      final items = entry.value;
      if (items.isEmpty) continue;
      final sample = items.first;
      final bigOrder = sample.bigOrder;
      final midOrder = sample.midOrder;
      bigNames.putIfAbsent(bigOrder, () => '대단원 ${bigOrder + 1}');
      midNames.putIfAbsent('$bigOrder|$midOrder', () => '중단원 ${midOrder + 1}');
      final mids =
          byBig.putIfAbsent(bigOrder, () => <int, List<TbExSmallUnit>>{});
      final smalls = mids.putIfAbsent(midOrder, () => <TbExSmallUnit>[]);
      smalls.add(
        _buildSmall(
          entry.key,
          sample.subKey.isEmpty ? '소단원' : sample.subKey,
          smalls.length,
          items,
        ),
      );
    }

    for (final bigEntry in byBig.entries) {
      final mids = <TbExMidUnit>[];
      for (final midEntry in bigEntry.value.entries) {
        mids.add(
          TbExMidUnit(
            name: midNames['${bigEntry.key}|${midEntry.key}'] ?? '중단원',
            order: midEntry.key,
            smalls: midEntry.value,
          ),
        );
      }
      mids.sort((a, b) => a.order.compareTo(b.order));
      units.add(
        TbExBigUnit(
          name: bigNames[bigEntry.key] ?? '대단원',
          order: bigEntry.key,
          mids: mids,
        ),
      );
    }
  }

  /// 페이지가 속한 소단원 버킷 인덱스. 겹치지 않는 범위 가정, 첫 매칭 반환.
  int? _conceptBucketForPage(List<_ConceptRange> ranges, int page) {
    if (page <= 0) return null;
    for (var i = 0; i < ranges.length; i += 1) {
      final r = ranges[i];
      final start = r.start;
      if (start == null) continue;
      final end = r.end ?? start;
      if (page >= start && page <= end) return i;
    }
    return null;
  }

  bool _isSpecialLectureItem(TbExItem item) {
    if (item.subKey.trim().toUpperCase() == 'E') return true;
    final blob = [
      item.section,
      item.typeGroupKind,
      item.typeGroupLabel,
      item.typeGroupTitle,
      item.difficultyLabel,
    ].join(' ').toLowerCase();
    return blob.contains('특강') || blob.contains('special_lecture');
  }

  /// sub_units 밖에 있는 특강(E) 문항·페이지를 가상 소단원으로 복원.
  TbExSmallUnit? _buildSpecialLectureSmall({
    required int bigOrder,
    required int midOrder,
    required _UnitMetaMid mid,
    required List<TbExItem> specialItems,
    required List<TbExItem> unassignedItems,
    _ConceptRange? normalizedRange,
  }) {
    final items = <TbExItem>[...specialItems, ...unassignedItems]
      ..sort(_compareItems);
    final subUnitPages = <int>{};
    var firstSubStart = 1 << 30;
    for (final small in mid.smalls) {
      subUnitPages.addAll(small.pageNumbers);
      final start = small.startPage;
      if (start != null && start > 0 && start < firstSubStart) {
        firstSubStart = start;
      }
    }
    final prefacePages = <int>{};
    if (firstSubStart < (1 << 30)) {
      for (final page in mid.categoryCoveredPages) {
        if (page > 0 && page < firstSubStart) prefacePages.add(page);
      }
    } else {
      // sub_units 페이지가 없으면 카테고리 페이지 − (없음) 범위 전체를 후보로.
      prefacePages.addAll(mid.categoryCoveredPages.difference(subUnitPages));
    }
    final metadataPages = <int>{...prefacePages};
    final normalizedStart = normalizedRange?.start;
    final normalizedEnd = normalizedRange?.end ?? normalizedStart;
    if (normalizedStart != null &&
        normalizedEnd != null &&
        normalizedStart > 0 &&
        normalizedEnd >= normalizedStart) {
      for (var page = normalizedStart; page <= normalizedEnd; page += 1) {
        metadataPages.add(page);
      }
    }
    for (final it in items) {
      final page = it.displayPage ?? it.rawPage;
      if (page > 0) metadataPages.add(page);
    }
    if (items.isEmpty && metadataPages.isEmpty) return null;

    // 소단원 1보다 앞에 오도록 order 를 최소값보다 작게.
    var minOrder = 0;
    for (final small in mid.smalls) {
      if (small.order < minOrder) minOrder = small.order;
    }
    return _buildSmall(
      '$bigOrder|$midOrder|E',
      '특강',
      minOrder - 1,
      items,
      metadataPageNumbers: metadataPages,
      includeMetadataPages: true,
    );
  }

  Map<String, _ConceptRange> _specialRangesFromRows(
    List<Map<String, dynamic>> rows,
  ) {
    final out = <String, _ConceptRange>{};
    final pattern = RegExp(r'^B:(\d+)/M:(\d+)/SPECIAL:E');
    for (final row in rows) {
      final match = pattern.firstMatch('${row['unit_key'] ?? ''}');
      if (match == null) continue;
      final bigOrder = int.tryParse(match.group(1) ?? '');
      final midOrder = int.tryParse(match.group(2) ?? '');
      final start = _toInt(row['display_start_page']);
      if (bigOrder == null || midOrder == null || start == null) continue;
      out['$bigOrder|$midOrder'] =
          _ConceptRange(start, _toInt(row['display_end_page']) ?? start);
    }
    return out;
  }

  int _compareSmallsByPage(TbExSmallUnit a, TbExSmallUnit b) {
    int earliest(TbExSmallUnit s) {
      if (s.pages.isNotEmpty) {
        return s.pages.first.displayPage ?? s.pages.first.rawPage;
      }
      if (s.metadataPageNumbers.isNotEmpty) {
        return s.metadataPageNumbers.reduce((x, y) => x < y ? x : y);
      }
      return s.order;
    }

    final byPage = earliest(a).compareTo(earliest(b));
    if (byPage != 0) return byPage;
    return a.order.compareTo(b.order);
  }

  int _compareItems(TbExItem a, TbExItem b) {
    final compared = compareTextbookProblemSourceOrder(
      TextbookProblemSourceOrderKey(
        bigOrder: a.bigOrder,
        midOrder: a.midOrder,
        subIndex: a.subIndex,
        subKey: a.subKey,
        page: a.displayPage ?? a.rawPage,
        problemNumber: a.problemNumber,
        ymin: a.ymin,
        xmin: a.xmin,
        stableId: a.cropId,
      ),
      TextbookProblemSourceOrderKey(
        bigOrder: b.bigOrder,
        midOrder: b.midOrder,
        subIndex: b.subIndex,
        subKey: b.subKey,
        page: b.displayPage ?? b.rawPage,
        problemNumber: b.problemNumber,
        ymin: b.ymin,
        xmin: b.xmin,
        stableId: b.cropId,
      ),
    );
    if (compared != 0) return compared;
    return a.sortOrder.compareTo(b.sortOrder);
  }

  List<_UnitMetaBig> _parseUnitMeta(dynamic payload) {
    if (payload is! Map) return const <_UnitMetaBig>[];
    final unitsRaw = payload['units'];
    if (unitsRaw is! List) return const <_UnitMetaBig>[];
    final bigs = <_UnitMetaBig>[];
    for (var bi = 0; bi < unitsRaw.length; bi += 1) {
      final bigMap = _asMap(unitsRaw[bi]);
      if (bigMap.isEmpty) continue;
      final bigOrder = _toInt(bigMap['order_index']) ?? bi;
      final bigName = '${bigMap['name'] ?? ''}'.trim();
      final mids = <_UnitMetaMid>[];
      final midsRaw = bigMap['middles'];
      if (midsRaw is List) {
        for (var mi = 0; mi < midsRaw.length; mi += 1) {
          final midMap = _asMap(midsRaw[mi]);
          if (midMap.isEmpty) continue;
          final midOrder = _toInt(midMap['order_index']) ?? mi;
          final midName = '${midMap['name'] ?? ''}'.trim();
          // 개념서면 sub_units(실제 소단원), 그 외면 smalls(A~D)를 소단원으로.
          final isConcept = midHasSubUnits(midMap);
          final display = displaySubUnitsForMid(midMap);
          final smalls = <_UnitMetaSmall>[];
          for (var si = 0; si < display.length; si += 1) {
            final d = display[si];
            smalls.add(
              _UnitMetaSmall(
                order: d.order,
                subKey: d.subKey,
                name: d.name,
                pageNumbers: _metadataPagesForSmall(d.raw),
                startPage: d.startPage,
                endPage: d.endPage,
              ),
            );
          }
          // A~D 카테고리 페이지 범위(특강 등 sub_units 밖 preface 복원용).
          final categoryCoveredPages = <int>{};
          if (isConcept) {
            final categorySmalls = midMap['smalls'];
            if (categorySmalls is List) {
              for (final rawSmall in categorySmalls) {
                categoryCoveredPages
                    .addAll(_metadataPagesForSmall(_asMap(rawSmall)));
              }
            }
          }
          mids.add(
            _UnitMetaMid(
              order: midOrder,
              name: midName.isEmpty ? '중단원 ${midOrder + 1}' : midName,
              smalls: smalls,
              isConcept: isConcept,
              categoryCoveredPages: categoryCoveredPages,
            ),
          );
        }
      }
      bigs.add(
        _UnitMetaBig(
          order: bigOrder,
          name: bigName.isEmpty ? '대단원 ${bigOrder + 1}' : bigName,
          mids: mids,
        ),
      );
    }
    return bigs;
  }

  int _computeTotalPages(dynamic payload, List<TbExItem> items) {
    var maxPage = 0;
    if (payload is Map) {
      final unitsRaw = payload['units'];
      if (unitsRaw is List) {
        for (final big in unitsRaw) {
          final bigMap = _asMap(big);
          final midsRaw = bigMap['middles'];
          if (midsRaw is! List) continue;
          for (final mid in midsRaw) {
            final midMap = _asMap(mid);
            final smallsRaw = midMap['smalls'];
            if (smallsRaw is! List) continue;
            for (final small in smallsRaw) {
              final smallMap = _asMap(small);
              final end = _toInt(smallMap['end_page']) ?? 0;
              final start = _toInt(smallMap['start_page']) ?? 0;
              if (end > maxPage) maxPage = end;
              if (start > maxPage) maxPage = start;
            }
          }
        }
      }
    }
    for (final item in items) {
      if (item.rawPage > maxPage) maxPage = item.rawPage;
    }
    return maxPage;
  }

  Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map) {
      return value.map((k, v) => MapEntry('$k', v));
    }
    return const <String, dynamic>{};
  }

  int? _toInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  Set<int> _metadataPagesForSmall(Map<String, dynamic> smallMap) {
    final pages = <int>{};
    final start = _toInt(smallMap['start_page']);
    final end = _toInt(smallMap['end_page']);
    if (start != null && end != null && start > 0 && end >= start) {
      for (var page = start; page <= end; page += 1) {
        pages.add(page);
      }
    } else if (start != null && start > 0) {
      pages.add(start);
    }
    final pageCounts = smallMap['page_counts'];
    if (pageCounts is Map) {
      for (final key in pageCounts.keys) {
        final page = _toInt(key);
        if (page != null && page > 0) pages.add(page);
      }
    }
    return pages;
  }

  List<int>? _toIntList(dynamic value) {
    if (value is! List) return null;
    final out = <int>[];
    for (final v in value) {
      final n = _toInt(v);
      if (n == null) return null;
      out.add(n);
    }
    return out;
  }
}

class _ConceptRange {
  _ConceptRange(this.start, this.end);
  final int? start;
  final int? end;
}

class _UnitMetaBig {
  _UnitMetaBig({required this.order, required this.name, required this.mids});
  final int order;
  final String name;
  final List<_UnitMetaMid> mids;
}

class _UnitMetaMid {
  _UnitMetaMid({
    required this.order,
    required this.name,
    required this.smalls,
    this.isConcept = false,
    this.categoryCoveredPages = const <int>{},
  });
  final int order;
  final String name;
  final List<_UnitMetaSmall> smalls;

  /// 개념서(개념원리)면 true. 이 경우 소단원은 sub_units 이고 문항은
  /// sub_key 가 아니라 페이지 범위로 소단원에 매핑한다.
  final bool isConcept;

  /// 개념서 A~D 카테고리 smalls 의 페이지 합집합. 특강 preface 복원에 사용.
  final Set<int> categoryCoveredPages;
}

class _UnitMetaSmall {
  _UnitMetaSmall({
    required this.order,
    required this.subKey,
    required this.name,
    required this.pageNumbers,
    this.startPage,
    this.endPage,
  });
  final int order;
  final String subKey;
  final String name;
  final Set<int> pageNumbers;

  /// 개념서 소단원의 교과서 표시 페이지 범위(문항 매핑용).
  final int? startPage;
  final int? endPage;
}
