import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Thin client for the gateway's `/textbook/vlm/detect-problems` endpoint.
///
/// Deliberately kept in its own file (not merged into `TextbookPdfService`)
/// so the dual-track migration surface stays untouched while we iterate on
/// the VLM test harness. The migration pane already reuses the upload path
/// from `TextbookPdfService`; this detection service is opt-in and only
/// referenced from the new "VLM 테스트" action row in the migration pane.
///
/// SECURITY TODO (pre-release): this uses the shared `PB_GATEWAY_API_KEY`.
/// Before we let end users trigger VLM detection, gate it behind per-user
/// JWT + academy membership just like the rest of `/textbook/*`.
class TextbookVlmTestService {
  TextbookVlmTestService({
    http.Client? httpClient,
    String? gatewayBaseUrl,
    String? gatewayApiKey,
  })  : _http = httpClient ?? http.Client(),
        _gatewayBaseUrl = _resolveGatewayUrl(gatewayBaseUrl),
        _gatewayApiKey = (gatewayApiKey ??
                const String.fromEnvironment('PB_GATEWAY_API_KEY',
                    defaultValue: ''))
            .trim();

  static String _resolveGatewayUrl(String? explicit) {
    if (explicit != null && explicit.trim().isNotEmpty) {
      return explicit.trim();
    }
    const dartDefine =
        String.fromEnvironment('PB_GATEWAY_URL', defaultValue: '');
    if (dartDefine.isNotEmpty) return dartDefine;
    try {
      final envValue = Platform.environment['PB_GATEWAY_URL'] ?? '';
      if (envValue.isNotEmpty) return envValue;
    } catch (_) {}
    return 'http://localhost:8787';
  }

  final http.Client _http;
  final String _gatewayBaseUrl;
  final String _gatewayApiKey;

  Uri _uri(String path) {
    final base = _gatewayBaseUrl.endsWith('/')
        ? _gatewayBaseUrl.substring(0, _gatewayBaseUrl.length - 1)
        : _gatewayBaseUrl;
    final p = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$base$p');
  }

  Map<String, String> _headers() {
    final out = <String, String>{
      'Content-Type': 'application/json',
    };
    if (_gatewayApiKey.isNotEmpty) {
      out['x-api-key'] = _gatewayApiKey;
    }
    return out;
  }

  /// Sends a single rendered PDF page to the gateway for VLM analysis.
  ///
  /// [imageBytes] should be a PNG (or JPEG/WebP) of the rendered page at a
  /// resolution high enough for problem numbers to be legible — we recommend
  /// rendering at least 1200 px on the long edge.
  ///
  /// [rawPage] is the 1-based PDF page index (not the book-face page).
  /// The gateway looks up `textbook_metadata.page_offset` for
  /// `(academyId, bookId, gradeLabel)` and returns `display_page` so the
  /// caller does not need to recompute.
  Future<TextbookVlmDetectResult> detectProblemsOnPage({
    required Uint8List imageBytes,
    required int rawPage,
    required String academyId,
    required String bookId,
    required String gradeLabel,
    String? sectionHint,
    String? expectedStartNumber,
    String? series,
    String mimeType = 'image/png',
  }) async {
    final body = <String, dynamic>{
      'image_base64': base64Encode(imageBytes),
      'mime_type': mimeType,
      'raw_page': rawPage,
      'academy_id': academyId,
      'book_id': bookId,
      'grade_label': gradeLabel,
      if ((sectionHint ?? '').trim().isNotEmpty)
        'section_hint': sectionHint!.trim(),
      if ((expectedStartNumber ?? '').trim().isNotEmpty)
        'expected_start_number': expectedStartNumber!.trim(),
      // 교재 시리즈 키 (ssen | rpm). 게이트웨이가 시리즈별 VLM 프롬프트를 고른다.
      if ((series ?? '').trim().isNotEmpty) 'series': series!.trim(),
    };
    final res = await _http.post(
      _uri('/textbook/vlm/detect-problems'),
      headers: _headers(),
      body: jsonEncode(body),
    );
    Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(res.body);
      json = decoded is Map<String, dynamic>
          ? decoded
          : (decoded is Map
              ? decoded.map((k, dynamic v) => MapEntry('$k', v))
              : <String, dynamic>{});
    } catch (_) {
      json = <String, dynamic>{};
    }
    if (res.statusCode < 200 || res.statusCode >= 300 || json['ok'] != true) {
      final detail = <String>[];
      if (json['error'] != null) detail.add('${json['error']}');
      if (json['message'] != null) detail.add('${json['message']}');
      if (json['fallback_message'] != null) {
        detail.add('fallback=${json['fallback_message']}');
      }
      final summary = detail.isEmpty ? res.body : detail.join(' / ');
      throw Exception(
        'vlm_detect_failed(${res.statusCode}): $summary',
      );
    }
    return TextbookVlmDetectResult.fromMap(json);
  }

  /// 목차(차례) 페이지 PNG 들을 한 번에 보내 단원 트리를 추출한다.
  ///
  /// 응답은 책에 인쇄된 계층 그대로이며 (대단원 > 중단원 > 소단원),
  /// 우리 단원 구조로의 매핑(예: 개념원리는 중단원→대단원, 소단원→중단원)은
  /// 호출자가 시리즈 규칙에 따라 수행한다.
  Future<TextbookTocParseResult> parseToc({
    required List<Uint8List> pageImages,
    String? series,
    String mimeType = 'image/png',
  }) async {
    final body = <String, dynamic>{
      'images': [
        for (final bytes in pageImages)
          <String, dynamic>{
            'image_base64': base64Encode(bytes),
            'mime_type': mimeType,
          },
      ],
      if ((series ?? '').trim().isNotEmpty) 'series': series!.trim(),
    };
    final res = await _http.post(
      _uri('/textbook/vlm/parse-toc'),
      headers: _headers(),
      body: jsonEncode(body),
    );
    Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(res.body);
      json = decoded is Map<String, dynamic>
          ? decoded
          : (decoded is Map
              ? decoded.map((k, dynamic v) => MapEntry('$k', v))
              : <String, dynamic>{});
    } catch (_) {
      json = <String, dynamic>{};
    }
    if (res.statusCode < 200 || res.statusCode >= 300 || json['ok'] != true) {
      final detail = <String>[];
      if (json['error'] != null) detail.add('${json['error']}');
      if (json['message'] != null) detail.add('${json['message']}');
      final summary = detail.isEmpty ? res.body : detail.join(' / ');
      throw Exception('vlm_toc_failed(${res.statusCode}): $summary');
    }
    return TextbookTocParseResult.fromMap(json);
  }

  /// 쎈/RPM 중단원 본문 페이지 묶음의 A/B/C 파트를 경량 분류한다.
  ///
  /// 문항 좌표는 추출하지 않고 `유형 익히기`/`시험에 꼭 나오는 문제`
  /// 시작 헤더와 페이지별 파트만 반환한다. 한 호출은 최대 24페이지다.
  Future<TextbookRpmSectionParseResult> classifyProblemBookSections({
    required List<TextbookRpmSectionImage> images,
    required String series,
    String mimeType = 'image/png',
  }) async {
    final body = <String, dynamic>{
      'images': [
        for (final image in images)
          <String, dynamic>{
            'image_base64': base64Encode(image.bytes),
            'mime_type': mimeType,
            'raw_page': image.rawPage,
          },
      ],
      'series': series.trim().toLowerCase(),
    };
    final res = await _http.post(
      _uri('/textbook/vlm/classify-problem-book-sections'),
      headers: _headers(),
      body: jsonEncode(body),
    );
    Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(res.body);
      json = decoded is Map<String, dynamic>
          ? decoded
          : (decoded is Map
              ? decoded.map((k, dynamic v) => MapEntry('$k', v))
              : <String, dynamic>{});
    } catch (_) {
      json = <String, dynamic>{};
    }
    if (res.statusCode < 200 || res.statusCode >= 300 || json['ok'] != true) {
      final detail = <String>[];
      if (json['error'] != null) detail.add('${json['error']}');
      if (json['message'] != null) detail.add('${json['message']}');
      final summary = detail.isEmpty ? res.body : detail.join(' / ');
      throw Exception('vlm_rpm_section_failed(${res.statusCode}): $summary');
    }
    return TextbookRpmSectionParseResult.fromMap(json);
  }
}

/// `/textbook/vlm/parse-toc` 응답 — 책에 인쇄된 계층 그대로의 단원 트리.
class TextbookTocParseResult {
  const TextbookTocParseResult({
    required this.bigUnits,
    required this.notes,
    this.appendixBoundaryPage,
  });

  final List<TextbookTocBigUnit> bigUnits;
  final String notes;
  final int? appendixBoundaryPage;

  factory TextbookTocParseResult.fromMap(Map<String, dynamic> map) {
    final bigs = <TextbookTocBigUnit>[];
    for (final raw in (map['big_units'] as List?) ?? const []) {
      if (raw is! Map) continue;
      final name = '${raw['name'] ?? ''}'.trim();
      if (name.isEmpty) continue;
      final mids = <TextbookTocMidUnit>[];
      for (final rawMid in (raw['mid_units'] as List?) ?? const []) {
        if (rawMid is! Map) continue;
        final midName = '${rawMid['name'] ?? ''}'.trim();
        if (midName.isEmpty) continue;
        final subs = <TextbookTocSubUnit>[];
        for (final rawSub in (rawMid['sub_units'] as List?) ?? const []) {
          if (rawSub is! Map) continue;
          final subName = '${rawSub['name'] ?? ''}'.trim();
          if (subName.isEmpty) continue;
          subs.add(TextbookTocSubUnit(
            name: subName,
            page: int.tryParse('${rawSub['page'] ?? ''}'),
            isExercise: rawSub['is_exercise'] == true || subName == '연습문제',
          ));
        }
        mids.add(TextbookTocMidUnit(
          name: midName,
          page: int.tryParse('${rawMid['page'] ?? ''}'),
          hasExercise: rawMid['has_exercise'] == true,
          subUnits: subs,
        ));
      }
      bigs.add(TextbookTocBigUnit(name: name, midUnits: mids));
    }
    return TextbookTocParseResult(
      bigUnits: bigs,
      notes: '${map['notes'] ?? ''}'.trim(),
      appendixBoundaryPage:
          int.tryParse('${map['appendix_boundary_page'] ?? ''}'),
    );
  }
}

class TextbookTocBigUnit {
  const TextbookTocBigUnit({required this.name, required this.midUnits});
  final String name;
  final List<TextbookTocMidUnit> midUnits;
}

class TextbookTocMidUnit {
  const TextbookTocMidUnit({
    required this.name,
    required this.hasExercise,
    required this.subUnits,
    this.page,
  });
  final String name;
  final int? page;
  final bool hasExercise;
  final List<TextbookTocSubUnit> subUnits;
}

class TextbookTocSubUnit {
  const TextbookTocSubUnit({
    required this.name,
    this.page,
    this.isExercise = false,
  });
  final String name;
  final int? page;

  /// "연습문제" 항목 여부. 소단원 사이사이에 여러 번 나올 수 있어
  /// 위치(순서)가 보존된 채로 전달된다.
  final bool isExercise;
}

class TextbookRpmSectionImage {
  const TextbookRpmSectionImage({
    required this.rawPage,
    required this.bytes,
  });

  final int rawPage;
  final Uint8List bytes;
}

class TextbookRpmSectionPage {
  const TextbookRpmSectionPage({
    required this.rawPage,
    required this.section,
    required this.typePracticeHeaderVisible,
    required this.masteryHeaderVisible,
  });

  final int rawPage;
  final String section;
  final bool typePracticeHeaderVisible;
  final bool masteryHeaderVisible;
}

class TextbookRpmSectionParseResult {
  const TextbookRpmSectionParseResult({
    required this.pages,
    required this.notes,
  });

  final List<TextbookRpmSectionPage> pages;
  final String notes;

  factory TextbookRpmSectionParseResult.fromMap(Map<String, dynamic> map) {
    final pages = <TextbookRpmSectionPage>[];
    for (final raw in (map['pages'] as List?) ?? const []) {
      if (raw is! Map) continue;
      final rawPage = int.tryParse('${raw['raw_page'] ?? ''}');
      if (rawPage == null || rawPage <= 0) continue;
      pages.add(TextbookRpmSectionPage(
        rawPage: rawPage,
        section: '${raw['section'] ?? 'unknown'}'.trim(),
        typePracticeHeaderVisible: raw['type_practice_header_visible'] == true,
        masteryHeaderVisible: raw['mastery_header_visible'] == true,
      ));
    }
    pages.sort((a, b) => a.rawPage.compareTo(b.rawPage));
    return TextbookRpmSectionParseResult(
      pages: pages,
      notes: '${map['notes'] ?? ''}'.trim(),
    );
  }
}

/// Parsed response of `/textbook/vlm/detect-problems`.
class TextbookVlmDetectResult {
  const TextbookVlmDetectResult({
    required this.rawPage,
    required this.displayPage,
    required this.pageOffset,
    required this.pageOffsetFound,
    required this.section,
    required this.pageKind,
    required this.conceptDrillHeaderVisible,
    required this.layout,
    required this.items,
    required this.notes,
    required this.model,
    required this.elapsedMs,
    required this.finishReason,
    this.usage,
  });

  final int rawPage;
  final int displayPage;
  final int pageOffset;
  final bool pageOffsetFound;

  /// One of 'basic_drill' | 'type_practice' | 'mastery' | 'unknown'.
  /// Maps to the Korean textbook unit structure
  /// (기본다잡기 / 유형뽀개기 / 만점도전하기) so the UI can group results.
  final String section;

  /// 'problem_page' | 'concept_page' | 'mixed' | 'unknown'.
  /// Concept-only A pages are intentionally returned with zero items so the
  /// UI can mark the page without persisting a fake problem region.
  final String pageKind;

  /// 이 페이지에 정확한 인쇄 문구 "개념원리 익히기"가 실제로 보이는지.
  /// 개념원리 일반 소단원에서 개념 페이지와 문항 시작 경계를 결정한다.
  final bool conceptDrillHeaderVisible;

  /// 'two_column' | 'one_column' | 'unknown'
  final String layout;
  final List<TextbookVlmItem> items;
  final String notes;
  final String model;
  final int elapsedMs;
  final String finishReason;
  final Map<String, dynamic>? usage;

  factory TextbookVlmDetectResult.fromMap(Map<String, dynamic> map) {
    int asInt(dynamic v) {
      if (v == null) return 0;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse('$v') ?? 0;
    }

    final rawItems = (map['items'] as List?) ?? const [];
    final parsed = <TextbookVlmItem>[];
    for (final r in rawItems) {
      if (r is Map) {
        parsed.add(
          TextbookVlmItem.fromMap(r.map((k, dynamic v) => MapEntry('$k', v))),
        );
      }
    }

    final sec = '${map['section'] ?? 'unknown'}';
    const allowedSections = {
      'basic_drill',
      'type_practice',
      'mastery',
      // 개념원리 전용 섹션 (sub_key A/B/C/D 슬롯 대응).
      'concept_drill',
      'type_example',
      'check',
      'exercise',
      'unknown',
    };
    final section = allowedSections.contains(sec) ? sec : 'unknown';
    final pageKind = '${map['page_kind'] ?? 'unknown'}';
    final synthesis = _synthesizeBasicDrillItemRegions(
      section: section,
      pageKind: pageKind,
      items: parsed,
    );
    final notes = _appendDetectNote(
      '${map['notes'] ?? ''}',
      synthesis.filled > 0
          ? 'manager_basic_drill_synthesized_item_region=${synthesis.filled}'
          : '',
    );

    return TextbookVlmDetectResult(
      rawPage: asInt(map['raw_page']),
      displayPage: asInt(map['display_page']),
      pageOffset: asInt(map['page_offset']),
      pageOffsetFound: map['page_offset_found'] == true,
      section: section,
      pageKind: pageKind,
      conceptDrillHeaderVisible: map['concept_drill_header_visible'] == true,
      layout: '${map['layout'] ?? 'unknown'}',
      items: synthesis.items,
      notes: notes,
      model: '${map['model'] ?? ''}',
      elapsedMs: asInt(map['elapsed_ms']),
      finishReason: '${map['finish_reason'] ?? ''}',
      usage: (map['usage'] is Map)
          ? (map['usage'] as Map).map((k, dynamic v) => MapEntry('$k', v))
          : null,
    );
  }
}

class TextbookVlmItem {
  const TextbookVlmItem({
    required this.number,
    required this.label,
    required this.isSetHeader,
    required this.setFrom,
    required this.setTo,
    required this.contentGroupKind,
    required this.contentGroupLabel,
    required this.contentGroupTitle,
    required this.contentGroupOrder,
    required this.column,
    required this.bbox,
    required this.itemRegion,
    this.category = '',
  });

  final String number;
  final String label;

  /// 개념원리(wonri) 단일 패스 전용 — 문항 카테고리.
  /// 'concept_drill' | 'type_example' | 'check' | 'exercise' | ''(비-wonri).
  /// sub_key A~D 슬롯과 1:1 대응한다.
  final String category;
  final bool isSetHeader;
  final int? setFrom;
  final int? setTo;
  final String contentGroupKind;
  final String contentGroupLabel;
  final String contentGroupTitle;
  final int? contentGroupOrder;

  /// 1 = left column, 2 = right column, null = single-column or unknown.
  final int? column;

  /// Normalized [ymin, xmin, ymax, xmax] in 0..1000. Minimal box around the
  /// problem *number* glyph itself. null if bbox missing.
  final List<int>? bbox;

  /// Normalized [ymin, xmin, ymax, xmax] in 0..1000. Full region occupied by
  /// the problem on the page (stem + choices + figures). null if the VLM did
  /// not return one or rejected it.
  final List<int>? itemRegion;

  factory TextbookVlmItem.fromMap(Map<String, dynamic> map) {
    int? asIntN(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse('$v');
    }

    List<int>? parseBbox(dynamic raw) {
      if (raw is! List || raw.length != 4) return null;
      final out = <int>[];
      for (final v in raw) {
        final n = asIntN(v);
        if (n == null) return null;
        out.add(n);
      }
      return out;
    }

    final number = '${map['number'] ?? ''}';
    final inferredRange = _basicDrillRangeMatch(number);
    final setRangeRaw = map['set_range'];
    int? from;
    int? to;
    if (setRangeRaw is Map) {
      from = asIntN(setRangeRaw['from']);
      to = asIntN(setRangeRaw['to']);
    }
    if ((from == null || to == null) && inferredRange != null) {
      from = int.tryParse(inferredRange.group(1)!);
      to = int.tryParse(inferredRange.group(2)!);
    }
    final groupRaw = map['content_group'];
    final group = groupRaw is Map
        ? groupRaw.map((k, dynamic v) => MapEntry('$k', v))
        : const <String, dynamic>{};
    final groupKind =
        '${map['content_group_kind'] ?? group['kind'] ?? 'none'}'.trim();
    final safeGroupKind =
        const {'basic_subtopic', 'type', 'none'}.contains(groupKind)
            ? groupKind
            : 'none';

    const allowedCategories = {
      'concept_drill',
      'type_example',
      'check',
      'exercise',
    };
    final categoryRaw = '${map['category'] ?? ''}'.trim();

    return TextbookVlmItem(
      number: number,
      label: '${map['label'] ?? ''}',
      category: allowedCategories.contains(categoryRaw) ? categoryRaw : '',
      isSetHeader: map['is_set_header'] == true || inferredRange != null,
      setFrom: from,
      setTo: to,
      contentGroupKind: safeGroupKind,
      contentGroupLabel: safeGroupKind == 'none'
          ? ''
          : '${map['content_group_label'] ?? group['label'] ?? ''}'.trim(),
      contentGroupTitle: safeGroupKind == 'none'
          ? ''
          : '${map['content_group_title'] ?? group['title'] ?? ''}'.trim(),
      contentGroupOrder: asIntN(map['content_group_order'] ?? group['order']),
      column: asIntN(map['column']),
      bbox: parseBbox(map['bbox']),
      itemRegion: parseBbox(map['item_region']),
    );
  }

  TextbookVlmItem copyWith({
    int? column,
    List<int>? bbox,
    List<int>? itemRegion,
  }) {
    return TextbookVlmItem(
      number: number,
      label: label,
      category: category,
      isSetHeader: isSetHeader,
      setFrom: setFrom,
      setTo: setTo,
      contentGroupKind: contentGroupKind,
      contentGroupLabel: contentGroupLabel,
      contentGroupTitle: contentGroupTitle,
      contentGroupOrder: contentGroupOrder,
      column: column ?? this.column,
      bbox: bbox ?? this.bbox,
      itemRegion: itemRegion ?? this.itemRegion,
    );
  }
}

class _ItemRegionSynthesis {
  const _ItemRegionSynthesis({
    required this.items,
    required this.filled,
  });

  final List<TextbookVlmItem> items;
  final int filled;
}

class _BasicDrillCandidate {
  const _BasicDrillCandidate({
    required this.index,
    required this.item,
    required this.bbox,
  });

  final int index;
  final TextbookVlmItem item;
  final List<int> bbox;
}

_ItemRegionSynthesis _synthesizeBasicDrillItemRegions({
  required String section,
  required String pageKind,
  required List<TextbookVlmItem> items,
}) {
  if (section != 'basic_drill' ||
      pageKind == 'concept_page' ||
      items.isEmpty ||
      items.every((item) => (item.itemRegion?.length ?? 0) == 4)) {
    return _ItemRegionSynthesis(items: items, filled: 0);
  }

  final columns = <int, List<_BasicDrillCandidate>>{};
  for (var i = 0; i < items.length; i += 1) {
    final item = items[i];
    final bbox = item.bbox;
    if (!_isBasicDrillNumberForSynthesis(item) ||
        bbox == null ||
        bbox.length != 4) {
      continue;
    }
    final key = item.column == 1 || item.column == 2
        ? item.column!
        : _inferColumn(bbox);
    columns.putIfAbsent(key, () => <_BasicDrillCandidate>[]).add(
          _BasicDrillCandidate(index: i, item: item, bbox: bbox),
        );
  }
  if (columns.isEmpty) {
    return _ItemRegionSynthesis(items: items, filled: 0);
  }

  final out = List<TextbookVlmItem>.of(items);
  var filled = 0;
  for (final columnItems in columns.values) {
    columnItems.sort((a, b) {
      final dy = a.bbox[0] - b.bbox[0];
      return dy.abs() > 12 ? dy : a.bbox[1] - b.bbox[1];
    });
    for (var i = 0; i < columnItems.length; i += 1) {
      final candidate = columnItems[i];
      if ((candidate.item.itemRegion?.length ?? 0) == 4) continue;
      final bbox = candidate.bbox;
      final next = i + 1 < columnItems.length ? columnItems[i + 1].bbox : null;
      final yMin = _clamp01k(bbox[0] - 4);
      final minBottom = bbox[2] + 52;
      final minHeightBottom = bbox[0] + 64;
      final defaultBottom =
          _clamp01k(minBottom > minHeightBottom ? minBottom : minHeightBottom);
      var yMax = defaultBottom;
      if (next != null) {
        final beforeNext = next[0] - 6;
        if (beforeNext < yMax) yMax = beforeNext;
      }
      if (yMax < yMin + 20) yMax = yMin + 20;
      yMax = _clamp01k(yMax);
      final xMin = _clamp01k(bbox[3] + 8);
      final xMax = _clamp01k(_inferColumn(bbox) == 1 ? 486 : 930);
      if (xMax <= xMin + 20 || yMax <= yMin + 12) continue;
      out[candidate.index] = candidate.item.copyWith(
        itemRegion: <int>[yMin, xMin, yMax, xMax],
      );
      filled += 1;
    }
  }

  return _ItemRegionSynthesis(items: out, filled: filled);
}

bool _isBasicDrillNumberForSynthesis(TextbookVlmItem item) {
  final number = item.number.trim();
  if (item.isSetHeader) {
    return _basicDrillRangeMatch(number) != null;
  }
  return RegExp(r'^\d{4}$').hasMatch(number);
}

RegExpMatch? _basicDrillRangeMatch(String number) {
  return RegExp(r'^(\d{4})\s*[~\-\u2013\u2014\u301c]\s*(\d{4})$')
      .firstMatch(number.trim());
}

int _inferColumn(List<int> bbox) {
  final centerX = (bbox[1] + bbox[3]) / 2;
  return centerX >= 500 ? 2 : 1;
}

int _clamp01k(int value) {
  if (value < 0) return 0;
  if (value > 1000) return 1000;
  return value;
}

String _appendDetectNote(String notes, String suffix) {
  final trimmed = notes.trim();
  if (suffix.trim().isEmpty || trimmed.contains(suffix)) return trimmed;
  return trimmed.isEmpty ? suffix : '$trimmed; $suffix';
}
