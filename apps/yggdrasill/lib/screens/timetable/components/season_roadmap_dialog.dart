import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../models/academic_season.dart';
import '../../../models/season_roadmap_entry.dart';
import '../../../services/data_manager.dart';
import '../../../services/textbook_concept_units.dart';
import '../../../widgets/utility_glass_dialog_shell.dart';
import '../../design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';

/// 시간 메뉴 시즌 라벨 → 시즌 로드맵 (조회 전용, 중앙 글래스 다이얼로그).
Future<void> showSeasonRoadmapDialog({
  required BuildContext context,
  required int seasonYear,
  required AcademicSeasonCode selectedSeasonCode,
}) {
  final yearLabel = (seasonYear % 100).toString().padLeft(2, '0');
  final seasonPill = AcademicSeason(
    year: seasonYear,
    code: selectedSeasonCode,
  ).shortLabel;

  return showUtilityGlassDialog(
    context: context,
    title: '$yearLabel 시즌 로드맵',
    icon: Symbols.route,
    maxWidth: 920,
    maxHeight: 760,
    preferredWidth: 920,
    headerTrailing: Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xFF16201D),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: const Color(0xFF33A373).withValues(alpha: 0.45),
          ),
        ),
        child: Text(
          seasonPill,
          style: const TextStyle(
            color: Color(0xFFEAF2F2),
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    ),
    child: _SeasonRoadmapBody(
      seasonYear: seasonYear,
      selectedSeasonCode: selectedSeasonCode,
    ),
  );
}

class _SeasonRoadmapBody extends StatefulWidget {
  const _SeasonRoadmapBody({
    required this.seasonYear,
    required this.selectedSeasonCode,
  });

  final int seasonYear;
  final AcademicSeasonCode selectedSeasonCode;

  @override
  State<_SeasonRoadmapBody> createState() => _SeasonRoadmapBodyState();
}

class _SeasonRoadmapBodyState extends State<_SeasonRoadmapBody> {
  late final Future<_SeasonRoadmapViewData> _future;

  @override
  void initState() {
    super.initState();
    _future = _loadSeasonRoadmapViewData(widget.seasonYear);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '교재탭 과정과 연결된 시즌별 학습 계획입니다. 연결된 교재의 대·중·소단원을 자동으로 펼쳐 보여줍니다.',
            style: TextStyle(
              color: Color(0xB3FFFFFF),
              fontSize: 13,
              decoration: TextDecoration.none,
            ),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: FutureBuilder<_SeasonRoadmapViewData>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(
                    child: CircularProgressIndicator(
                      color: Color(0xFF33A373),
                    ),
                  );
                }
                if (snapshot.hasError) {
                  return Center(
                    child: Text(
                      '로드맵을 불러오지 못했습니다.\n${snapshot.error}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xB3FFFFFF),
                        decoration: TextDecoration.none,
                      ),
                    ),
                  );
                }
                final data = snapshot.data ??
                    const _SeasonRoadmapViewData(
                      entries: <SeasonRoadmapEntry>[],
                      booksByCourseKey: <String, List<_CourseBookUnits>>{},
                    );
                return _SeasonRoadmapContent(
                  seasonYear: widget.seasonYear,
                  selectedSeasonCode: widget.selectedSeasonCode,
                  data: data,
                );
              },
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            '조회 전용입니다. 단원은 교재 메타데이터(TOC)에서 자동으로 가져옵니다.',
            style: TextStyle(
              color: Color(0x66FFFFFF),
              fontSize: 12,
              decoration: TextDecoration.none,
            ),
          ),
        ],
      ),
    );
  }
}

class _SeasonRoadmapViewData {
  const _SeasonRoadmapViewData({
    required this.entries,
    required this.booksByCourseKey,
  });

  final List<SeasonRoadmapEntry> entries;

  /// courseKey = gradeKey 또는 `label:${normalizedLabel}`
  final Map<String, List<_CourseBookUnits>> booksByCourseKey;
}

class _CourseBookUnits {
  const _CourseBookUnits({
    required this.bookId,
    required this.bookName,
    required this.gradeLabel,
    required this.units,
  });

  final String bookId;
  final String bookName;
  final String gradeLabel;
  final List<_BigUnitNode> units;
}

class _BigUnitNode {
  const _BigUnitNode({
    required this.name,
    required this.orderIndex,
    required this.middles,
  });

  final String name;
  final int orderIndex;
  final List<_MidUnitNode> middles;
}

class _MidUnitNode {
  const _MidUnitNode({
    required this.name,
    required this.orderIndex,
    required this.smalls,
  });

  final String name;
  final int orderIndex;
  final List<_SmallUnitNode> smalls;
}

class _SmallUnitNode {
  const _SmallUnitNode({
    required this.name,
    required this.orderIndex,
  });

  final String name;
  final int orderIndex;
}

String _normalizeLabel(String value) => value.trim().toLowerCase();

String _courseLookupKey(SeasonRoadmapEntry entry) {
  final gradeKey = (entry.gradeKey ?? '').trim();
  if (gradeKey.isNotEmpty) return 'gk:$gradeKey';
  return 'label:${_normalizeLabel(entry.courseLabelSnapshot)}';
}

int _orderIndex(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim()) ?? (1 << 30);
  return 1 << 30;
}

List<_BigUnitNode> _parseUnits(dynamic payload) {
  if (payload is! Map) return const <_BigUnitNode>[];
  final unitsRaw = payload['units'];
  if (unitsRaw is! List) return const <_BigUnitNode>[];
  final units = unitsRaw
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList()
    ..sort((a, b) =>
        _orderIndex(a['order_index']).compareTo(_orderIndex(b['order_index'])));

  final out = <_BigUnitNode>[];
  for (final u in units) {
    final middles = <_MidUnitNode>[];
    final midsRaw = u['middles'];
    if (midsRaw is List) {
      final mids = midsRaw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList()
        ..sort((a, b) => _orderIndex(a['order_index'])
            .compareTo(_orderIndex(b['order_index'])));
      for (final m in mids) {
        final smalls = displaySubUnitsForMid(m)
            .map(
              (s) => _SmallUnitNode(
                name: s.name,
                orderIndex: s.order,
              ),
            )
            .toList();
        middles.add(
          _MidUnitNode(
            name: (m['name'] as String?)?.trim().isNotEmpty == true
                ? (m['name'] as String).trim()
                : '중단원',
            orderIndex: _orderIndex(m['order_index']),
            smalls: smalls,
          ),
        );
      }
    }
    out.add(
      _BigUnitNode(
        name: (u['name'] as String?)?.trim().isNotEmpty == true
            ? (u['name'] as String).trim()
            : '대단원',
        orderIndex: _orderIndex(u['order_index']),
        middles: middles,
      ),
    );
  }
  return out;
}

Future<_SeasonRoadmapViewData> _loadSeasonRoadmapViewData(int seasonYear) async {
  final dm = DataManager.instance;
  final entries = await dm.loadSeasonRoadmapForYear(seasonYear);
  final textbooks = await dm.loadTextbooksWithMetadata();
  final books = await dm.loadAnswerKeyBooks();
  final grades = await dm.loadAnswerKeyGrades();

  final labelByGradeKey = <String, String>{};
  for (final row in grades) {
    final key = (row['grade_key'] ?? '').toString().trim();
    final label = (row['label'] ?? '').toString().trim();
    if (key.isEmpty || label.isEmpty) continue;
    labelByGradeKey[key] = label;
  }

  final bookNameById = <String, String>{};
  final bookIdsByGradeKey = <String, List<String>>{};
  for (final row in books) {
    final id = (row['id'] ?? '').toString().trim();
    final name = (row['name'] ?? '').toString().trim();
    final gradeKey = (row['grade_key'] ?? '').toString().trim();
    if (id.isEmpty) continue;
    bookNameById[id] = name.isEmpty ? '(이름 없음)' : name;
    if (gradeKey.isNotEmpty) {
      bookIdsByGradeKey.putIfAbsent(gradeKey, () => <String>[]).add(id);
    }
  }

  final textbookByBookAndLabel = <String, _CourseBookUnits>{};
  final textbooksByNormalizedLabel = <String, List<_CourseBookUnits>>{};
  for (final row in textbooks) {
    final bookId = (row['book_id'] ?? '').toString().trim();
    final gradeLabel = (row['grade_label'] ?? '').toString().trim();
    if (bookId.isEmpty || gradeLabel.isEmpty) continue;
    final units = _parseUnits(row['payload']);
    if (units.isEmpty) continue;
    final bookName = (row['book_name'] ?? '').toString().trim();
    final item = _CourseBookUnits(
      bookId: bookId,
      bookName: bookName.isEmpty
          ? (bookNameById[bookId] ?? '(이름 없음)')
          : bookName,
      gradeLabel: gradeLabel,
      units: units,
    );
    textbookByBookAndLabel['$bookId|$gradeLabel'] = item;
    textbooksByNormalizedLabel
        .putIfAbsent(_normalizeLabel(gradeLabel), () => <_CourseBookUnits>[])
        .add(item);
  }

  final booksByCourseKey = <String, List<_CourseBookUnits>>{};

  void putBooks(String courseKey, Iterable<_CourseBookUnits> items) {
    if (items.isEmpty) return;
    final list =
        booksByCourseKey.putIfAbsent(courseKey, () => <_CourseBookUnits>[]);
    final seen = list.map((e) => '${e.bookId}|${e.gradeLabel}').toSet();
    for (final item in items) {
      final key = '${item.bookId}|${item.gradeLabel}';
      if (!seen.add(key)) continue;
      list.add(item);
    }
  }

  for (final entry in entries) {
    final courseKey = _courseLookupKey(entry);
    final gradeKey = (entry.gradeKey ?? '').trim();
    final labels = <String>{
      entry.courseLabelSnapshot.trim(),
      if (gradeKey.isNotEmpty) (labelByGradeKey[gradeKey] ?? '').trim(),
    }..removeWhere((e) => e.isEmpty);

    for (final label in labels) {
      putBooks(
        courseKey,
        textbooksByNormalizedLabel[_normalizeLabel(label)] ??
            const <_CourseBookUnits>[],
      );
    }

    if (gradeKey.isNotEmpty) {
      final linkedBookIds = bookIdsByGradeKey[gradeKey] ?? const <String>[];
      for (final bookId in linkedBookIds) {
        for (final label in labels) {
          final exact = textbookByBookAndLabel['$bookId|$label'];
          if (exact != null) {
            putBooks(courseKey, [exact]);
            continue;
          }
        }
        // 라벨이 달라도 같은 book_id 메타가 있으면 포함
        final fallback = textbookByBookAndLabel.values
            .where((e) => e.bookId == bookId)
            .toList();
        putBooks(courseKey, fallback);
      }
    }
  }

  return _SeasonRoadmapViewData(
    entries: entries,
    booksByCourseKey: booksByCourseKey,
  );
}

class _SeasonRoadmapContent extends StatelessWidget {
  const _SeasonRoadmapContent({
    required this.seasonYear,
    required this.selectedSeasonCode,
    required this.data,
  });

  final int seasonYear;
  final AcademicSeasonCode selectedSeasonCode;
  final _SeasonRoadmapViewData data;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: AcademicSeasonCode.values.map((code) {
          final seasonEntries = data.entries
              .where((entry) => entry.seasonCode == code)
              .toList();
          return _SeasonRoadmapCard(
            season: AcademicSeason(year: seasonYear, code: code),
            selected: selectedSeasonCode == code,
            entries: seasonEntries,
            booksByCourseKey: data.booksByCourseKey,
          );
        }).toList(),
      ),
    );
  }
}

class _SeasonRoadmapCard extends StatelessWidget {
  const _SeasonRoadmapCard({
    required this.season,
    required this.selected,
    required this.entries,
    required this.booksByCourseKey,
  });

  final AcademicSeason season;
  final bool selected;
  final List<SeasonRoadmapEntry> entries;
  final Map<String, List<_CourseBookUnits>> booksByCourseKey;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final panelStyle = FabTabBarTokens.previewAcademyPanelStyleFor(brightness);
    const radius = FabTabBarTokens.previewAcademyGroupedCardRadius;
    final borderColor = selected
        ? const Color(0xFF33A373)
        : panelStyle.border.withValues(alpha: 0.55);

    return Container(
      width: 430,
      constraints: const BoxConstraints(minHeight: 150),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
      decoration: BoxDecoration(
        color: panelStyle.groupedCardBackground,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderColor, width: selected ? 1.4 : 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                season.shortLabel,
                style: TextStyle(
                  color: panelStyle.title,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  decoration: TextDecoration.none,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  season.displayName,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: panelStyle.hint,
                    fontSize: 13,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                '방학/지정 과정 없음',
                style: TextStyle(
                  color: panelStyle.hint,
                  fontSize: 14,
                  decoration: TextDecoration.none,
                ),
              ),
            )
          else
            ...entries.map(
              (entry) => _SeasonRoadmapCourseBlock(
                entry: entry,
                books: booksByCourseKey[_courseLookupKey(entry)] ??
                    const <_CourseBookUnits>[],
              ),
            ),
        ],
      ),
    );
  }
}

class _SeasonRoadmapCourseBlock extends StatelessWidget {
  const _SeasonRoadmapCourseBlock({
    required this.entry,
    required this.books,
  });

  final SeasonRoadmapEntry entry;
  final List<_CourseBookUnits> books;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final panelStyle = FabTabBarTokens.previewAcademyPanelStyleFor(brightness);
    final courseText = entry.isOptional
        ? '${entry.courseLabelSnapshot} (선택)'
        : entry.courseLabelSnapshot;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 72,
                child: Text(
                  entry.targetLabel,
                  style: TextStyle(
                    color: panelStyle.label,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  courseText,
                  style: TextStyle(
                    color: panelStyle.title,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
              if (!entry.hasLinkedCourse) ...[
                const SizedBox(width: 6),
                Tooltip(
                  message: '교재탭 과정 미연결',
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF4A3420),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: const Color(0xFFE0A340)),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          color: Color(0xFFFFC66D),
                          size: 14,
                        ),
                        SizedBox(width: 4),
                        Text(
                          '미연결',
                          style: TextStyle(
                            color: Color(0xFFFFDCA3),
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          if (books.isEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 80),
              child: Text(
                entry.hasLinkedCourse
                    ? '등록된 단원 정보 없음'
                    : '과정 연결 후 단원이 표시됩니다',
                style: TextStyle(
                  color: panelStyle.hint,
                  fontSize: 12,
                  decoration: TextDecoration.none,
                ),
              ),
            )
          else
            ...books.map((book) => _BookUnitsTree(book: book)),
        ],
      ),
    );
  }
}

class _BookUnitsTree extends StatelessWidget {
  const _BookUnitsTree({required this.book});

  final _CourseBookUnits book;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final panelStyle = FabTabBarTokens.previewAcademyPanelStyleFor(brightness);
    final theme = Theme.of(context).copyWith(
      dividerColor: Colors.transparent,
      expansionTileTheme: ExpansionTileThemeData(
        backgroundColor: Colors.transparent,
        collapsedBackgroundColor: Colors.transparent,
        iconColor: panelStyle.chevron,
        collapsedIconColor: panelStyle.chevron,
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(left: 10, bottom: 4),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(left: 8, top: 2),
      child: Theme(
        data: theme,
        child: ExpansionTile(
          initiallyExpanded: true,
          dense: true,
          visualDensity: VisualDensity.compact,
          title: Text(
            book.bookName,
            style: TextStyle(
              color: panelStyle.rowValue,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              decoration: TextDecoration.none,
            ),
          ),
          children: book.units
              .map(
                (big) => ExpansionTile(
                  initiallyExpanded: true,
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  title: Text(
                    big.name,
                    style: TextStyle(
                      color: panelStyle.title,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  children: big.middles
                      .map(
                        (mid) => ExpansionTile(
                          initiallyExpanded: true,
                          dense: true,
                          visualDensity: VisualDensity.compact,
                          title: Text(
                            mid.name,
                            style: TextStyle(
                              color: panelStyle.label,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              decoration: TextDecoration.none,
                            ),
                          ),
                          children: mid.smalls.isEmpty
                              ? [
                                  Padding(
                                    padding: const EdgeInsets.only(
                                      left: 12,
                                      bottom: 6,
                                    ),
                                    child: Text(
                                      '소단원 없음',
                                      style: TextStyle(
                                        color: panelStyle.hint,
                                        fontSize: 12,
                                        decoration: TextDecoration.none,
                                      ),
                                    ),
                                  ),
                                ]
                              : mid.smalls
                                  .map(
                                    (small) => Padding(
                                      padding: const EdgeInsets.only(
                                        left: 12,
                                        bottom: 5,
                                      ),
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: Text(
                                          '· ${small.name}',
                                          style: TextStyle(
                                            color: panelStyle.inputText,
                                            fontSize: 12,
                                            decoration: TextDecoration.none,
                                          ),
                                        ),
                                      ),
                                    ),
                                  )
                                  .toList(),
                        ),
                      )
                      .toList(),
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}
