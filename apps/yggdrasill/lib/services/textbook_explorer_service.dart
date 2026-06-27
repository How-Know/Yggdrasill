import '../screens/learning/models/problem_bank_export_models.dart';
import 'data_manager.dart';
import 'learning_problem_bank_service.dart';
import 'tenant_service.dart';

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
  final int sortOrder;

  bool get hasUid => questionUid.trim().isNotEmpty;
  bool get hasRegion => xmax > xmin && ymax > ymin;

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
  });

  final String key;
  final String name;
  final int order;
  final List<TbExItem> items;
  final List<TbExPage> pages;

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
    final number = '${row['problem_number'] ?? ''}'.trim();
    final isSetHeader = row['is_set_header'] == true;
    if (number.isEmpty && !isSetHeader) return null;
    double frac(int index) {
      if (region == null || region.length != 4) return 0;
      return (region[index] / 1000.0).clamp(0.0, 1.0);
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
      xmin: frac(1),
      ymin: frac(0),
      xmax: frac(3),
      ymax: frac(2),
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
    for (final item in items) {
      final key = '${item.bigOrder}|${item.midOrder}|${item.subKey}';
      itemsByKey.putIfAbsent(key, () => <TbExItem>[]).add(item);
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
          for (final small in mid.smalls) {
            final key = '${big.order}|${mid.order}|${small.subKey}';
            final list = itemsByKey[key] ?? const <TbExItem>[];
            if (list.isEmpty) continue;
            usedKeys.add(key);
            smalls.add(_buildSmall(key, small.name, small.order, list));
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
    List<TbExItem> items,
  ) {
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
          final smalls = <_UnitMetaSmall>[];
          final smallsRaw = midMap['smalls'];
          if (smallsRaw is List) {
            for (var si = 0; si < smallsRaw.length; si += 1) {
              final smallMap = _asMap(smallsRaw[si]);
              if (smallMap.isEmpty) continue;
              final smallOrder = _toInt(smallMap['order_index']) ?? si;
              final subKey = '${smallMap['sub_key'] ?? ''}'.trim();
              final smallName = '${smallMap['name'] ?? ''}'.trim();
              smalls.add(
                _UnitMetaSmall(
                  order: smallOrder,
                  subKey: subKey,
                  name: smallName.isEmpty ? '소단원' : smallName,
                ),
              );
            }
          }
          mids.add(
            _UnitMetaMid(
              order: midOrder,
              name: midName.isEmpty ? '중단원 ${midOrder + 1}' : midName,
              smalls: smalls,
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

class _UnitMetaBig {
  _UnitMetaBig({required this.order, required this.name, required this.mids});
  final int order;
  final String name;
  final List<_UnitMetaMid> mids;
}

class _UnitMetaMid {
  _UnitMetaMid({required this.order, required this.name, required this.smalls});
  final int order;
  final String name;
  final List<_UnitMetaSmall> smalls;
}

class _UnitMetaSmall {
  _UnitMetaSmall(
      {required this.order, required this.subKey, required this.name});
  final int order;
  final String subKey;
  final String name;
}
