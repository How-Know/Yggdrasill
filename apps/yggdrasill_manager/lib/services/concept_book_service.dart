import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'textbook_pdf_page_renderer.dart';
import 'textbook_pdf_service.dart';
import 'textbook_series_catalog.dart';

/// 개념 탭 "개념책 불러오기". 이미 저장된 교재 구조(textbook_metadata 단원·쪽 범위)와 문항 기록
/// (textbook_problem_crops)만 읽어 쪽마다 표시를 만든다. 새로 추출·저장하지 않는다.
/// 설계: docs/architecture/concept-library.md
class ConceptBookEntry {
  const ConceptBookEntry({
    required this.academyId,
    required this.bookId,
    required this.bookName,
    required this.gradeLabel,
    required this.textbookType,
    required this.units,
    this.seriesKey,
  });

  factory ConceptBookEntry.fromMetadataRow(Map<String, dynamic> row, {String? bookName}) {
    final payload = row['payload'] is Map ? Map<String, dynamic>.from(row['payload'] as Map) : null;
    final type = (row['textbook_type'] as String?)?.trim() ?? '';
    final series = _text(payload?['series']);
    return ConceptBookEntry(
      academyId: row['academy_id'] as String,
      bookId: row['book_id'] as String,
      bookName: bookName,
      gradeLabel: (row['grade_label'] as String?) ?? '',
      textbookType: type.isEmpty ? null : type,
      seriesKey: series.isEmpty ? null : series,
      units: conceptBookUnitsFromPayload(payload),
    );
  }

  final String academyId;
  final String bookId;

  /// 사용자 권한으로 볼 수 없으면 null(지어내지 않는다).
  final String? bookName;
  final String gradeLabel;

  /// 저장된 값 그대로. 비어 있으면 null(종류 미지정).
  final String? textbookType;

  /// 단원 구조에 저장된 시리즈 키. 교재 등록 마법사로 만든 구조에만 있다.
  final String? seriesKey;
  final List<ConceptBookUnit> units;

  TextbookSeriesCatalogEntry? get series => seriesKey == null ? null : textbookSeriesByKey(seriesKey!);
  String? get seriesName => series?.displayName ?? seriesKey;

  /// 종류가 개념서로 저장됐거나 개념서 시리즈로 등록된 교재. 저장된 종류는 그대로 둔다.
  bool get isConceptBook => textbookType == '개념서' || series?.defaultTextbookType == '개념서';

  int get subUnitCount => units.where((u) => !u.slot).length;
  int get slotCount => units.where((u) => u.slot).length;
  String get key => '$academyId|$bookId|$gradeLabel';
}

/// 단원 구조의 소단원 하나(저장된 값 그대로).
class ConceptBookUnit {
  const ConceptBookUnit({required this.path, this.startPage, this.endPage, this.isExercise = false, this.slot = false});

  /// 대단원 > 중단원 > 소단원 이름. 빈 이름은 뺀다.
  final List<String> path;
  final int? startPage;
  final int? endPage;
  final bool isExercise;

  /// 실제 소단원 목록이 없는 중단원이라 문항 묶음(A·B·C… 칸)을 대신 보인다.
  final bool slot;
}

/// 단원 구조를 저장된 순서대로 소단원 목록으로 읽는다. 중단원에 실제 소단원 목록(sub_units)이 있으면 그것을,
/// 없으면 smalls를 쓴다. smalls 중 문항 묶음 키(sub_key)가 없는 것은 예전 교재 탭에서 저장한 실제 소단원이다.
List<ConceptBookUnit> conceptBookUnitsFromPayload(Map<String, dynamic>? payload) {
  final series = textbookSeriesByKey(_text(payload?['series']));
  String presetName(String key) {
    for (final p in series?.subPreset ?? const <TextbookSubSectionPreset>[]) {
      if (p.key.toUpperCase() == key) return p.displayName;
    }
    return key;
  }

  final out = <ConceptBookUnit>[];
  for (final big in _maps(payload?['units'])) {
    final bigName = _text(big['name']);
    for (final mid in _maps(big['middles'])) {
      final midName = _text(mid['name']);
      final subUnits = [for (final s in _maps(mid['sub_units'])) if (_text(s['name']).isNotEmpty) s];
      if (subUnits.isNotEmpty) {
        for (final s in subUnits) {
          out.add(ConceptBookUnit(
            path: _path(bigName, midName, _text(s['name'])),
            startPage: _int(s['start_page']),
            endPage: _int(s['end_page']),
            isExercise: s['is_exercise'] == true,
          ));
        }
        continue;
      }
      for (final s in _maps(mid['smalls'])) {
        final key = _text(s['sub_key']).toUpperCase();
        final stored = _text(s['name']);
        final name = stored.isNotEmpty || key.isEmpty ? stored : presetName(key);
        if (name.isEmpty) continue;
        out.add(ConceptBookUnit(
          path: _path(bigName, midName, name),
          startPage: _int(s['start_page']),
          endPage: _int(s['end_page']),
          isExercise: s['is_exercise'] == true,
          slot: key.isNotEmpty,
        ));
      }
    }
  }
  return out;
}

List<Map<String, dynamic>> _maps(dynamic raw) =>
    raw is List ? [for (final v in raw) if (v is Map) Map<String, dynamic>.from(v)] : const [];

String _text(dynamic v) => v == null ? '' : '$v'.trim();

int? _int(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

List<String> _path(String big, String mid, String sub) => [big, mid, sub].where((s) => s.isNotEmpty).toList();

/// 한 쪽의 문항 기록(문항 수와 인쇄된 쪽 번호).
class ConceptBookCropPage {
  const ConceptBookCropPage({required this.problems, this.displayPage});

  final int problems;
  final int? displayPage;
}

class ConceptBookPage {
  const ConceptBookPage({required this.rawPage, required this.problems, this.displayPage});

  /// PDF 쪽(1부터). 단원 구조의 쪽 범위는 PDF 쪽 그대로다.
  final int rawPage;
  final int problems;

  /// 문항 기록에 있는 인쇄 쪽. 문항이 없는 쪽은 모른다(null).
  final int? displayPage;
}

/// 소단원 하나의 쪽 목록과 표시.
class ConceptBookUnitPages {
  const ConceptBookUnitPages({
    required this.path,
    required this.isExercise,
    required this.pages,
    required this.extracted,
    this.startPage,
    this.endPage,
    this.capped = false,
    this.slot = false,
  });

  /// 대단원 > 중단원 > 소단원 이름(저장된 값 그대로).
  final List<String> path;
  final bool isExercise;
  final int? startPage;
  final int? endPage;
  final List<ConceptBookPage> pages;

  /// 이 소단원 쪽 범위에 문항 기록이 하나라도 있다. 없으면 추출 전일 수 있어 쪽 표시를 하지 않는다.
  final bool extracted;

  /// 쪽 범위가 너무 길어 앞부분만 보인다.
  final bool capped;

  /// 소단원이 아니라 문항 묶음(A·B·C… 칸)의 쪽 범위다.
  final bool slot;

  bool get hasRange => startPage != null && endPage != null && endPage! >= startPage!;

  /// 문항 기록이 있는 소단원에서 문항이 없는 쪽. 문항 묶음 범위에는 표시하지 않는다.
  bool isConceptPage(ConceptBookPage page) => extracted && !slot && page.problems == 0;
}

const int kConceptBookMaxPagesPerUnit = 80;

/// 저장된 단원 구조와 문항 기록으로 쪽 표시를 만든다(추정하지 않는다).
List<ConceptBookUnitPages> conceptBookUnitPages(List<ConceptBookUnit> units, Map<int, ConceptBookCropPage> crops) {
  final out = <ConceptBookUnitPages>[];
  for (final unit in units) {
    final start = unit.startPage;
    final end = unit.endPage;
    if (start == null || end == null || start < 1 || end < start) {
      out.add(ConceptBookUnitPages(
        path: unit.path,
        isExercise: unit.isExercise,
        startPage: start,
        endPage: end,
        pages: const [],
        extracted: false,
        slot: unit.slot,
      ));
      continue;
    }
    final last = (end - start + 1) > kConceptBookMaxPagesPerUnit ? start + kConceptBookMaxPagesPerUnit - 1 : end;
    final pages = [
      for (var raw = start; raw <= last; raw += 1)
        ConceptBookPage(rawPage: raw, problems: crops[raw]?.problems ?? 0, displayPage: crops[raw]?.displayPage),
    ];
    var extracted = false;
    for (var raw = start; raw <= end; raw += 1) {
      if ((crops[raw]?.problems ?? 0) > 0) {
        extracted = true;
        break;
      }
    }
    out.add(ConceptBookUnitPages(
      path: unit.path,
      isExercise: unit.isExercise,
      startPage: start,
      endPage: end,
      pages: pages,
      extracted: extracted,
      capped: last < end,
      slot: unit.slot,
    ));
  }
  return out;
}

class ConceptBookService {
  ConceptBookService({SupabaseClient? client, TextbookPdfService? pdf, http.Client? httpClient})
      : _client = client,
        _pdf = pdf ?? TextbookPdfService(),
        _http = httpClient ?? http.Client();

  final SupabaseClient? _client;
  final TextbookPdfService _pdf;
  final http.Client _http;

  SupabaseClient get _db => _client ?? Supabase.instance.client;

  /// 단원 구조가 저장된 교재(학년별). 책 이름은 볼 수 있는 것만.
  Future<List<ConceptBookEntry>> listBooks() async {
    final rows = await _db
        .from('textbook_metadata')
        .select('academy_id,book_id,grade_label,textbook_type,payload')
        .order('book_id', ascending: true)
        .order('grade_label', ascending: true)
        .limit(500);
    final list = (rows as List).map((r) => Map<String, dynamic>.from(r as Map)).toList();
    final ids = {for (final r in list) r['book_id'] as String};
    final names = <String, String>{};
    if (ids.isNotEmpty) {
      final files = await _db.from('resource_files').select('id,name').inFilter('id', ids.toList());
      for (final f in (files as List)) {
        final m = Map<String, dynamic>.from(f as Map);
        final name = (m['name'] as String?)?.trim() ?? '';
        if (name.isNotEmpty) names[m['id'] as String] = name;
      }
    }
    final out = [for (final r in list) ConceptBookEntry.fromMetadataRow(r, bookName: names[r['book_id']])];
    // 이름·학년이 같은 항목이 여럿이면 교재 등록 마법사로 만든 구조(시리즈 키 있음)를 먼저 둔다.
    out.sort((a, b) {
      final n = (a.bookName ?? '\uffff').compareTo(b.bookName ?? '\uffff');
      if (n != 0) return n;
      final g = a.gradeLabel.compareTo(b.gradeLabel);
      if (g != 0) return g;
      final s = (a.seriesKey == null ? 1 : 0).compareTo(b.seriesKey == null ? 1 : 0);
      return s != 0 ? s : a.bookId.compareTo(b.bookId);
    });
    return out;
  }

  /// 문항 기록 수(목록 표시용). 행은 읽지 않고 개수만 센다.
  Future<int> problemCount(ConceptBookEntry book) async {
    return _db
        .from('textbook_problem_crops')
        .count(CountOption.exact)
        .eq('academy_id', book.academyId)
        .eq('book_id', book.bookId)
        .eq('grade_label', book.gradeLabel);
  }

  /// 쪽마다 문항 수. PostgREST 한 번에 1000행 제한이 있어 나눠 읽는다.
  Future<Map<int, ConceptBookCropPage>> problemPages(ConceptBookEntry book) async {
    final counts = <int, int>{};
    final display = <int, int>{};
    const pageSize = 1000;
    for (var from = 0;; from += pageSize) {
      final rows = await _db
          .from('textbook_problem_crops')
          .select('raw_page,display_page')
          .eq('academy_id', book.academyId)
          .eq('book_id', book.bookId)
          .eq('grade_label', book.gradeLabel)
          .order('raw_page', ascending: true)
          .order('id', ascending: true)
          .range(from, from + pageSize - 1);
      final list = rows as List;
      for (final r in list) {
        final m = r as Map;
        final raw = (m['raw_page'] as num?)?.toInt();
        if (raw == null || raw <= 0) continue;
        counts[raw] = (counts[raw] ?? 0) + 1;
        final d = (m['display_page'] as num?)?.toInt();
        if (d != null && d > 0) display.putIfAbsent(raw, () => d);
      }
      if (list.length < pageSize) break;
    }
    return {
      for (final e in counts.entries) e.key: ConceptBookCropPage(problems: e.value, displayPage: display[e.key]),
    };
  }

  /// 원본 PDF 주소(짧게 쓰는 서명 주소).
  Future<String> originalUrl({required String academyId, required String bookId, required String gradeLabel}) async {
    final target = await _pdf.requestDownloadUrl(
      academyId: academyId,
      fileId: bookId,
      gradeLabel: gradeLabel,
      kind: 'body',
      requireMigratedStorage: true,
    );
    if (target.url.isEmpty) throw Exception('원본 PDF 주소가 비어 있습니다.');
    return target.url;
  }

  /// 고른 쪽을 PNG로 그려 임시 파일 경로를 돌려준다. PDF는 기기 임시 폴더에 받아 두고 다시 쓴다.
  Future<List<String>> renderPages(
    ConceptBookEntry book,
    List<int> rawPages, {
    void Function(int done, int total)? onProgress,
    int longEdgePx = 1600,
  }) async {
    final target = await _pdf.requestDownloadUrl(
      academyId: book.academyId,
      fileId: book.bookId,
      gradeLabel: book.gradeLabel,
      kind: 'body',
      requireMigratedStorage: true,
    );
    if (target.url.isEmpty) throw Exception('원본 PDF 주소가 비어 있습니다.');
    final temp = await getTemporaryDirectory();
    final dir = Directory(p.join(temp.path, 'yggdrasill_concept_book'));
    await dir.create(recursive: true);
    String safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9가-힣_-]'), '_');
    final identity = (target.contentHash ?? '').trim().isNotEmpty ? target.contentHash!.trim() : 'size_${target.fileSizeBytes ?? 0}';
    final pdfFile = File(p.join(dir.path, '${safe(book.bookId)}_${safe(book.gradeLabel)}_${safe(identity)}.pdf'));
    final expected = target.fileSizeBytes;
    final cached = await pdfFile.exists() && (expected == null || expected <= 0 || await pdfFile.length() == expected);
    if (!cached) {
      final res = await _http.get(Uri.parse(target.url));
      if (res.statusCode < 200 || res.statusCode >= 300) throw Exception('원본 PDF를 받지 못했습니다(${res.statusCode}).');
      final part = File('${pdfFile.path}.${DateTime.now().microsecondsSinceEpoch}.part');
      await part.writeAsBytes(res.bodyBytes, flush: true);
      if (await pdfFile.exists()) await pdfFile.delete();
      await part.rename(pdfFile.path);
    }
    final doc = await PdfDocument.openFile(pdfFile.path);
    try {
      final out = <String>[];
      for (var i = 0; i < rawPages.length; i += 1) {
        final raw = rawPages[i];
        final png = await renderPdfPageToPng(document: doc, pageNumber: raw, longEdgePx: longEdgePx);
        final size = longEdgePx == 1600 ? '' : '_$longEdgePx';
        final name = '${safe(book.bookName ?? book.bookId)}_${safe(book.gradeLabel)}_p$raw$size.png';
        final file = File(p.join(dir.path, name));
        await file.writeAsBytes(png, flush: true);
        out.add(file.path);
        onProgress?.call(i + 1, rawPages.length);
      }
      return out;
    } finally {
      await doc.dispose();
    }
  }
}
