import '../screens/learning/models/problem_bank_export_models.dart';
import 'data_manager.dart';
import 'learning_problem_bank_service.dart';
import 'tenant_service.dart';
import 'textbook_concept_units.dart';

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
    required this.questionUid,
    required this.problemNumber,
    required this.difficultyLabel,
    required this.answerKind,
    required this.typeGroupKind,
    required this.typeGroupLabel,
    required this.typeGroupTitle,
    required this.rawPage,
    required this.displayPage,
    required this.bigOrder,
    required this.midOrder,
    required this.subKey,
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

  final String questionUid;
  final String problemNumber;
  final String difficultyLabel;
  final TbAnswerKind answerKind;
  final String typeGroupKind;
  final String typeGroupLabel;
  final String typeGroupTitle;
  final int rawPage;
  final int? displayPage;
  final int bigOrder;
  final int midOrder;
  final String subKey;
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

  TbExItem copyWith({TbAnswerKind? answerKind}) {
    return TbExItem(
      questionUid: questionUid,
      problemNumber: problemNumber,
      difficultyLabel: difficultyLabel,
      answerKind: answerKind ?? this.answerKind,
      typeGroupKind: typeGroupKind,
      typeGroupLabel: typeGroupLabel,
      typeGroupTitle: typeGroupTitle,
      rawPage: rawPage,
      displayPage: displayPage,
      bigOrder: bigOrder,
      midOrder: midOrder,
      subKey: subKey,
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

  Future<TbExData> load({
    required String bookId,
    required String gradeLabel,
  }) async {
    final safeBookId = bookId.trim();
    final safeGrade = gradeLabel.trim();
    if (safeBookId.isEmpty) return TbExData.empty;

    final payloadRow = await DataManager.instance.loadTextbookMetadataPayload(
      bookId: safeBookId,
      gradeLabel: safeGrade,
    );
    final cropRows = await DataManager.instance.loadTextbookProblemRegions(
      bookId: safeBookId,
      gradeLabel: safeGrade.isEmpty ? null : safeGrade,
    );

    final items = <TbExItem>[];
    var order = 0;
    for (final row in cropRows) {
      final item = _itemFromRow(row, order);
      if (item == null) continue;
      items.add(item);
      order += 1;
    }

    // 응답 유형(객/주/서)은 pb_questions 에서 보강한다.
    final uids = items
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

    final resolvedItems = items
        .map(
          (e) => e.hasUid && answerKindByUid.containsKey(e.questionUid)
              ? e.copyWith(answerKind: answerKindByUid[e.questionUid])
              : e,
        )
        .toList(growable: false);

    final units = _buildUnits(payloadRow?['payload'], resolvedItems);
    final itemsByPage = <int, List<TbExItem>>{};
    for (final item in resolvedItems) {
      if (item.rawPage <= 0) continue;
      itemsByPage.putIfAbsent(item.rawPage, () => <TbExItem>[]).add(item);
    }

    final totalPages =
        _computeTotalPages(payloadRow?['payload'], resolvedItems);
    final numberedUids = <String>{};
    var unnumberedNoUid = 0;
    for (final item in resolvedItems) {
      if (item.isSetHeader) continue;
      if (item.problemNumber.trim().isEmpty) continue;
      if (item.hasUid) {
        numberedUids.add(item.questionUid);
      } else {
        unnumberedNoUid += 1;
      }
    }
    final totalQuestions = numberedUids.length + unnumberedNoUid;

    return TbExData(
      units: units,
      itemsByPage: itemsByPage,
      totalPages: totalPages,
      totalQuestions: totalQuestions,
    );
  }

  TbExItem? _itemFromRow(Map<String, dynamic> row, int sortOrder) {
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

    return TbExItem(
      questionUid: '${row['pb_question_uid'] ?? ''}'.trim(),
      problemNumber: number,
      difficultyLabel: _normalizeDifficulty('${row['label'] ?? ''}'),
      answerKind: TbAnswerKind.unknown,
      typeGroupKind: '${row['content_group_kind'] ?? ''}'.trim(),
      typeGroupLabel: '${row['content_group_label'] ?? ''}'.trim(),
      typeGroupTitle: '${row['content_group_title'] ?? ''}'.trim(),
      rawPage: rawPage,
      displayPage: _toInt(row['display_page']),
      bigOrder: _toInt(row['big_order']) ?? 0,
      midOrder: _toInt(row['mid_order']) ?? 0,
      subKey: '${row['sub_key'] ?? ''}'.trim(),
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

  List<TbExBigUnit> _buildUnits(dynamic payload, List<TbExItem> items) {
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
            final midKey = '${big.order}|${mid.order}';
            final midItems = itemsByMid[midKey] ?? const <TbExItem>[];
            if (midItems.isNotEmpty) {
              final buckets =
                  List<List<TbExItem>>.generate(mid.smalls.length, (_) => []);
              final ranges = mid.smalls
                  .map((s) => _ConceptRange(s.startPage, s.endPage))
                  .toList(growable: false);
              for (final it in midItems) {
                final page = it.displayPage ?? it.rawPage;
                final idx = _conceptBucketForPage(ranges, page);
                if (idx != null) buckets[idx].add(it);
              }
              for (var si = 0; si < mid.smalls.length; si += 1) {
                final small = mid.smalls[si];
                final list = buckets[si];
                if (list.isEmpty) continue;
                list.sort(_compareItems);
                smalls.add(
                  _buildSmall(
                    '${big.order}|${mid.order}|${small.subKey}',
                    small.name,
                    small.order,
                    list,
                    small.pageNumbers,
                  ),
                );
              }
              // 이 중단원의 모든 sub_key 문항을 소비 처리(leftover 방지).
              for (final entry in itemsByKey.keys) {
                if (entry.startsWith('$midKey|')) usedKeys.add(entry);
              }
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
                  small.pageNumbers,
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
    List<TbExItem> items, [
    Set<int> metadataPageNumbers = const <int>{},
  ]) {
    final byPage = <int, List<TbExItem>>{};
    int? displayPageOf(int raw) {
      for (final it in items) {
        if (it.rawPage == raw && it.displayPage != null) return it.displayPage;
      }
      return null;
    }

    for (final it in items) {
      if (it.rawPage <= 0) continue;
      byPage.putIfAbsent(it.rawPage, () => <TbExItem>[]).add(it);
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

  int _compareItems(TbExItem a, TbExItem b) {
    final an = int.tryParse(a.problemNumber);
    final bn = int.tryParse(b.problemNumber);
    if (an != null && bn != null && an != bn) return an.compareTo(bn);
    if (an != null && bn == null) return -1;
    if (an == null && bn != null) return 1;
    if (a.rawPage != b.rawPage) return a.rawPage.compareTo(b.rawPage);
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
          mids.add(
            _UnitMetaMid(
              order: midOrder,
              name: midName.isEmpty ? '중단원 ${midOrder + 1}' : midName,
              smalls: smalls,
              isConcept: isConcept,
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
  });
  final int order;
  final String name;
  final List<_UnitMetaSmall> smalls;

  /// 개념서(개념원리)면 true. 이 경우 소단원은 sub_units 이고 문항은
  /// sub_key 가 아니라 페이지 범위로 소단원에 매핑한다.
  final bool isConcept;
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
