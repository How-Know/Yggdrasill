import 'package:supabase_flutter/supabase_flutter.dart';

import 'concept_book_service.dart';

/// 교재 순서로 다시 나열한 개념. 개념은 라이브러리 폴더에 그대로 있고, 순서는 출처(쪽·쪽 안 순서)에서 나온다.
/// 설계: docs/architecture/concept-library.md §5
enum ConceptPageOrderFrom {
  /// 확정할 때 출처에 저장한 값.
  stored,

  /// 쪽 안 순서 저장 전에 확정해 초안 기록(전사 블록 순서)으로 계산한 값.
  draft,

  /// 직접 이은 출처 등 쪽 안 순서를 모른다.
  unknown,
}

class ConceptBookOrderEntry {
  const ConceptBookOrderEntry({
    required this.conceptId,
    required this.name,
    required this.versionLabel,
    required this.folderPath,
    required this.unitPath,
    required this.rawPage,
    required this.displayPage,
    required this.pageOrder,
    required this.orderFrom,
    required this.pages,
  });

  final String conceptId;
  final String name;
  final String versionLabel;

  /// 라이브러리 폴더 경로(영역부터). 폴더를 읽지 못하면 비어 있다.
  final List<String> folderPath;

  /// 처음 나온 출처의 교재 단원 경로.
  final List<String> unitPath;

  /// 처음 나온 PDF 쪽과 그 인쇄 쪽.
  final int rawPage;
  final int? displayPage;

  /// 그 쪽 안에서 근거 블록이 처음 나온 자리(1부터). 모르면 null.
  final int? pageOrder;
  final ConceptPageOrderFrom orderFrom;

  /// 이 교재에서 출처로 이은 모든 PDF 쪽(오름차순).
  final List<int> pages;
}

class ConceptBookOrder {
  const ConceptBookOrder(this.entries);

  final List<ConceptBookOrderEntry> entries;

  int get computedFromDrafts => entries.where((e) => e.orderFrom == ConceptPageOrderFrom.draft).length;
  int get unknownOrder => entries.where((e) => e.orderFrom == ConceptPageOrderFrom.unknown).length;

  /// 처음 나온 단원이 바뀔 때마다 끊은 묶음. 순서는 entries 그대로다.
  List<({List<String> unit, List<ConceptBookOrderEntry> entries})> get byUnit {
    final out = <({List<String> unit, List<ConceptBookOrderEntry> entries})>[];
    for (final e in entries) {
      if (out.isEmpty || out.last.unit.join('\u0000') != e.unitPath.join('\u0000')) {
        out.add((unit: e.unitPath, entries: <ConceptBookOrderEntry>[]));
      }
      out.last.entries.add(e);
    }
    return out;
  }
}

Map<String, dynamic> _map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<Map<String, dynamic>> _maps(Object? v) => v is List
    ? [
        for (final e in v)
          if (e is Map) Map<String, dynamic>.from(e)
      ]
    : const [];
List<String> _strings(Object? v) => v is List
    ? [
        for (final e in v)
          if (e != null) e.toString()
      ]
    : const [];
int? _int(Object? v) => v is num ? v.toInt() : null;
String _key(String conceptId, int page) => '$conceptId\u0001$page';

/// 확정한 초안 기록 → (개념 id, 쪽) → 그 쪽 블록 중 근거 블록이 처음 나온 자리. 확정 RPC와 같은 규칙이다.
Map<String, int> conceptPageOrdersFromDrafts(Iterable<Map<String, dynamic>> drafts) {
  final out = <String, int>{};
  for (final d in drafts) {
    final pos = <String, ({int page, int pos})>{};
    final perPage = <int, int>{};
    for (final b in _maps(d['blocks'])) {
      final page = _int(b['raw_page']);
      final id = b['id']?.toString();
      if (page == null || id == null) continue;
      final n = (perPage[page] ?? 0) + 1;
      perPage[page] = n;
      pos[id] = (page: page, pos: n);
    }
    final aiConcepts = _maps(d['draft_concepts']);
    final reviewByKey = <String, Map<String, dynamic>>{};
    for (final it in _maps(d['review_concepts'])) {
      final index = _int(it['index']);
      final key = (it['key']?.toString().trim().isNotEmpty ?? false) ? it['key'].toString().trim() : 'c$index';
      reviewByKey[key] = it;
    }
    for (final c in _maps(_map(d['result'])['concepts'])) {
      final id = c['id']?.toString();
      final index = _int(c['index']);
      if (id == null || index == null) continue;
      final key = c['key']?.toString() ?? 'c$index';
      final item = reviewByKey[key];
      final blocks = item != null && item['blocks'] is List
          ? _strings(item['blocks'])
          : (index >= 0 && index < aiConcepts.length ? _strings(aiConcepts[index]['source_blocks']) : const <String>[]);
      for (final b in blocks) {
        final p = pos[b];
        if (p == null) continue;
        final k = _key(id, p.page);
        final cur = out[k];
        if (cur == null || p.pos < cur) out[k] = p.pos;
      }
    }
  }
  return out;
}

/// 폴더 표 → id별 영역부터의 경로.
Map<String, List<String>> conceptFolderPaths(Iterable<Map<String, dynamic>> categories) {
  final byId = {for (final c in categories) c['id'].toString(): c};
  final out = <String, List<String>>{};
  List<String> pathOf(String id) {
    final hit = out[id];
    if (hit != null) return hit;
    final path = <String>[];
    var cur = byId[id];
    for (var i = 0; cur != null && i < 12; i += 1) {
      path.insert(0, (cur['name'] ?? '').toString().trim());
      final parent = cur['parent_id']?.toString();
      cur = parent == null ? null : byId[parent];
    }
    return out[id] = path;
  }

  for (final id in byId.keys) {
    pathOf(id);
  }
  return out;
}

/// 출처 행(개념 이름·폴더 포함) → 교재 순서. 개념마다 처음 나온 쪽, 그 쪽 안 순서, 이름 순으로 놓는다.
ConceptBookOrder buildConceptBookOrder({
  required Iterable<Map<String, dynamic>> sources,
  Map<String, List<String>> folderPaths = const {},
  Map<String, int> draftOrders = const {},
}) {
  final byConcept = <String, List<Map<String, dynamic>>>{};
  for (final s in sources) {
    final id = s['concept_id']?.toString();
    if (id == null || _int(s['raw_page']) == null) continue;
    (byConcept[id] ??= []).add(s);
  }
  final entries = <ConceptBookOrderEntry>[];
  for (final MapEntry(key: id, value: rows) in byConcept.entries) {
    // 같은 쪽이 기본 서술과 다른 서술의 출처로 함께 이어질 수 있다. 그 쪽 안 순서를 아는 줄을 앞에 둔다.
    rows.sort((a, b) {
      final byPage = _int(a['raw_page'])!.compareTo(_int(b['raw_page'])!);
      if (byPage != 0) return byPage;
      final ao = _int(a['page_order']), bo = _int(b['page_order']);
      if (ao == bo) return 0;
      if (ao == null) return 1;
      if (bo == null) return -1;
      return ao.compareTo(bo);
    });
    final first = rows.first;
    final page = _int(first['raw_page'])!;
    final stored = _int(first['page_order']);
    final fromDraft = stored == null ? draftOrders[_key(id, page)] : null;
    final concept = _map(first['concepts']);
    entries.add(ConceptBookOrderEntry(
      conceptId: id,
      name: (concept['name'] ?? '').toString(),
      versionLabel: (concept['version_label'] ?? '').toString(),
      folderPath: folderPaths[concept['main_category_id']?.toString()] ?? const [],
      unitPath: _strings(first['unit_path']),
      rawPage: page,
      displayPage: _int(first['display_page']),
      pageOrder: stored ?? fromDraft,
      orderFrom: stored != null
          ? ConceptPageOrderFrom.stored
          : fromDraft != null
              ? ConceptPageOrderFrom.draft
              : ConceptPageOrderFrom.unknown,
      pages: {for (final r in rows) _int(r['raw_page'])!}.toList()..sort(),
    ));
  }
  entries.sort((a, b) {
    final byPage = a.rawPage.compareTo(b.rawPage);
    if (byPage != 0) return byPage;
    final ao = a.pageOrder, bo = b.pageOrder;
    if (ao != bo) {
      if (ao == null) return 1;
      if (bo == null) return -1;
      return ao.compareTo(bo);
    }
    return a.name.compareTo(b.name);
  });
  return ConceptBookOrder(entries);
}

class ConceptBookOrderService {
  ConceptBookOrderService({SupabaseClient? client}) : _client = client;

  final SupabaseClient? _client;
  SupabaseClient get _db => _client ?? Supabase.instance.client;

  static const _page = 1000;

  Future<List<Map<String, dynamic>>> _all(
      PostgrestTransformBuilder<List<Map<String, dynamic>>> Function(int from, int to) q) async {
    final out = <Map<String, dynamic>>[];
    for (var from = 0;; from += _page) {
      final rows = await q(from, from + _page - 1);
      out.addAll(rows);
      if (rows.length < _page) return out;
    }
  }

  Future<ConceptBookOrder> load(ConceptBookEntry book) async {
    final sources = await _all((from, to) => _db
        .from('concept_sources')
        .select(
            'id,concept_id,raw_page,display_page,unit_path,page_order,concepts(name,version_label,main_category_id)')
        .eq('academy_id', book.academyId)
        .eq('book_id', book.bookId)
        .eq('grade_label', book.gradeLabel)
        .order('id')
        .range(from, to));
    if (sources.isEmpty) return const ConceptBookOrder([]);
    final categories = await _all(
        (from, to) => _db.from('concept_categories').select('id,name,parent_id').order('id').range(from, to));
    var draftOrders = const <String, int>{};
    if (sources.any((s) => s['page_order'] == null)) {
      final drafts = await _all((from, to) => _db
          .from('concept_drafts')
          .select('id,result,review_concepts:review->concepts,draft_concepts:draft->concepts,blocks:prepared->blocks')
          .eq('academy_id', book.academyId)
          .eq('book_id', book.bookId)
          .eq('grade_label', book.gradeLabel)
          .eq('status', 'confirmed')
          .order('id')
          .range(from, to));
      draftOrders = conceptPageOrdersFromDrafts(drafts);
    }
    return buildConceptBookOrder(
        sources: sources, folderPaths: conceptFolderPaths(categories), draftOrders: draftOrders);
  }
}
