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
    return TextbookRpmSectionParseResult.fromMap(_decodeSectionJson(res));
  }

  /// 고쟁이 워크북 지면 묶음을 분류한다.
  ///
  /// 본문과 달리 워크북은 교재 맨 뒤에 묶음들이 몰려 있고, 지면마다 머리에
  /// "중단원 TEST"(소단원 이름) / "대단원 TEST"(대단원 이름) 배지가 반복
  /// 인쇄된다. 목차에는 워크북 시작 쪽 하나만 있어서, 이 훑기 없이는 E·F
  /// 슬롯의 쪽 범위를 채울 방법이 없다. 한 호출은 최대 24페이지다.
  Future<TextbookGojaengiWorkbookParseResult> classifyGojaengiWorkbookPages({
    required List<TextbookRpmSectionImage> images,
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
      'series': 'gojaengi',
      'scope': 'workbook',
    };
    final res = await _http.post(
      _uri('/textbook/vlm/classify-problem-book-sections'),
      headers: _headers(),
      body: jsonEncode(body),
    );
    return TextbookGojaengiWorkbookParseResult.fromMap(
      _decodeSectionJson(res),
    );
  }

  /// 중등 개념원리의 2단계 목차를 실제 소단원 행으로 보완한다.
  ///
  /// 목차에는 대단원/중단원만 인쇄되므로 중단원 본문을 훑어 정확히 보이는
  /// 소단원 머리말과 중단원 마무리 시작 지면을 찾는다.
  Future<TextbookWonriMiddleStructureResult> classifyWonriMiddleStructurePages({
    required List<TextbookRpmSectionImage> images,
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
      'series': 'wonri_middle',
      'scope': 'structure',
    };
    final res = await _http.post(
      _uri('/textbook/vlm/classify-problem-book-sections'),
      headers: _headers(),
      body: jsonEncode(body),
    );
    return TextbookWonriMiddleStructureResult.fromMap(
      _decodeSectionJson(res),
    );
  }

  Map<String, dynamic> _decodeSectionJson(http.Response res) {
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
    return json;
  }
}

class TextbookWonriMiddleStructurePage {
  const TextbookWonriMiddleStructurePage({
    required this.rawPage,
    required this.subUnitHeaderVisible,
    required this.subUnitName,
    required this.unitEndKind,
    required this.calculationHeaderVisible,
  });

  final int rawPage;
  final bool subUnitHeaderVisible;
  final String subUnitName;
  final String unitEndKind;
  final bool calculationHeaderVisible;

  factory TextbookWonriMiddleStructurePage.fromMap(
    Map<String, dynamic> map,
  ) {
    final raw = map['raw_page'];
    final rawPage = raw is num ? raw.toInt() : int.tryParse('$raw') ?? 0;
    return TextbookWonriMiddleStructurePage(
      rawPage: rawPage,
      subUnitHeaderVisible: map['sub_unit_header_visible'] == true,
      subUnitName: '${map['sub_unit_name'] ?? ''}'.trim(),
      unitEndKind:
          const {'review', 'descriptive'}.contains(map['unit_end_kind'])
              ? '${map['unit_end_kind']}'
              : 'none',
      calculationHeaderVisible: map['calculation_header_visible'] == true,
    );
  }
}

class TextbookWonriMiddleStructureResult {
  const TextbookWonriMiddleStructureResult({
    required this.pages,
    required this.notes,
  });

  final List<TextbookWonriMiddleStructurePage> pages;
  final String notes;

  factory TextbookWonriMiddleStructureResult.fromMap(
    Map<String, dynamic> map,
  ) {
    final rawPages = (map['pages'] as List?) ?? const <dynamic>[];
    return TextbookWonriMiddleStructureResult(
      pages: <TextbookWonriMiddleStructurePage>[
        for (final raw in rawPages)
          if (raw is Map)
            TextbookWonriMiddleStructurePage.fromMap(
              raw.map((key, dynamic value) => MapEntry('$key', value)),
            ),
      ],
      notes: '${map['notes'] ?? ''}'.trim(),
    );
  }
}

/// `/textbook/vlm/parse-toc` 응답 — 책에 인쇄된 계층 그대로의 단원 트리.
class TextbookTocParseResult {
  const TextbookTocParseResult({
    required this.bigUnits,
    required this.notes,
    this.appendixBoundaryPage,
    this.workbookMidTestPage,
    this.workbookBigTestPage,
  });

  final List<TextbookTocBigUnit> bigUnits;
  final String notes;
  final int? appendixBoundaryPage;

  /// 고쟁이 목차 맨 아래 "WORKBOOK" 묶음의 시작 쪽 (인쇄 쪽, 보정 전).
  ///
  /// 목차에는 두 묶음의 시작 쪽만 한 번씩 인쇄되고 대단원·중단원별 범위는
  /// 없다. 그 범위는 워크북 지면 머리말을 훑어야 나온다.
  final int? workbookMidTestPage;
  final int? workbookBigTestPage;

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
      workbookMidTestPage:
          int.tryParse('${map['workbook_mid_test_page'] ?? ''}'),
      workbookBigTestPage:
          int.tryParse('${map['workbook_big_test_page'] ?? ''}'),
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
    required this.headerVisible,
  });

  final int rawPage;
  final String section;

  /// 이 지면 상단에 [section] 파트의 머리말이 인쇄돼 있는지.
  /// 머리말은 파트가 시작되는 첫 지면에만 인쇄되므로 파트 경계 신호가 된다.
  final bool headerVisible;

  bool get typePracticeHeaderVisible =>
      section == 'type_practice' && headerVisible;

  bool get masteryHeaderVisible => section == 'mastery' && headerVisible;
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
      final section = '${raw['section'] ?? 'unknown'}'.trim();
      pages.add(TextbookRpmSectionPage(
        rawPage: rawPage,
        section: section,
        // 옛 응답(파트별 전용 플래그)도 그대로 받아 준다.
        headerVisible: raw['header_visible'] == true ||
            (section == 'type_practice' &&
                raw['type_practice_header_visible'] == true) ||
            (section == 'mastery' && raw['mastery_header_visible'] == true),
      ));
    }
    pages.sort((a, b) => a.rawPage.compareTo(b.rawPage));
    return TextbookRpmSectionParseResult(
      pages: pages,
      notes: '${map['notes'] ?? ''}'.trim(),
    );
  }
}

/// 고쟁이 워크북 지면 한 장의 묶음 머리말.
class TextbookGojaengiWorkbookPage {
  const TextbookGojaengiWorkbookPage({
    required this.rawPage,
    required this.corner,
    required this.unitNumber,
    required this.unitName,
  });

  final int rawPage;

  /// 'mid_unit_test' | 'big_unit_test' | 'unknown'.
  /// 머리말 배지가 안 보이는 이어지는 지면은 'unknown' 이고, 앞 지면에서
  /// 이어 준다.
  final String corner;

  /// 머리말의 단원 번호. 중단원 TEST 는 소단원 번호, 대단원 TEST 는 대단원
  /// 번호다. 이름 대조가 실패했을 때의 예비 단서로 쓴다.
  final int? unitNumber;

  /// 머리말의 단원 이름 (번호 제외).
  final String unitName;

  bool get hasHeader => corner != 'unknown' && unitName.isNotEmpty;
}

class TextbookGojaengiWorkbookParseResult {
  const TextbookGojaengiWorkbookParseResult({
    required this.pages,
    required this.notes,
  });

  final List<TextbookGojaengiWorkbookPage> pages;
  final String notes;

  factory TextbookGojaengiWorkbookParseResult.fromMap(
    Map<String, dynamic> map,
  ) {
    final pages = <TextbookGojaengiWorkbookPage>[];
    for (final raw in (map['pages'] as List?) ?? const []) {
      if (raw is! Map) continue;
      final rawPage = int.tryParse('${raw['raw_page'] ?? ''}');
      if (rawPage == null || rawPage <= 0) continue;
      pages.add(TextbookGojaengiWorkbookPage(
        rawPage: rawPage,
        corner: '${raw['corner'] ?? 'unknown'}'.trim(),
        unitNumber: int.tryParse('${raw['unit_number'] ?? ''}'),
        unitName: '${raw['unit_name'] ?? ''}'.trim(),
      ));
    }
    pages.sort((a, b) => a.rawPage.compareTo(b.rawPage));
    return TextbookGojaengiWorkbookParseResult(
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
    this.contentGroupFallback = false,
    this.contentGroupRequired = false,
    this.contentGroupMissing = false,
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
  final bool contentGroupFallback;
  final bool contentGroupRequired;
  final bool contentGroupMissing;
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
      // 수력충전 전용 섹션 (sub_key A/B 슬롯 대응).
      'type_problem',
      'unit_review',
      'unknown',
    };
    final section = allowedSections.contains(sec) ? sec : 'unknown';
    final pageKind = '${map['page_kind'] ?? 'unknown'}';
    final synthesis = _synthesizeBasicDrillItemRegions(
      section: section,
      pageKind: pageKind,
      items: parsed,
    );
    var notes = _appendDetectNote(
      '${map['notes'] ?? ''}',
      synthesis.filled > 0
          ? 'manager_basic_drill_synthesized_item_region=${synthesis.filled}'
          : '',
    );
    if (map['content_group_fallback'] == true) {
      notes = _appendDetectNote(notes, 'content_group_fallback');
    }
    if (map['content_group_missing'] == true) {
      notes = _appendDetectNote(notes, 'content_group_missing');
    }

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
      contentGroupFallback: map['content_group_fallback'] == true,
      contentGroupRequired: map['content_group_required'] == true,
      contentGroupMissing: map['content_group_missing'] == true,
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
    this.itemRole = '',
    this.companionRegions = const <Map<String, dynamic>>[],
    this.isImportant = false,
  });

  final String number;
  final String label;

  /// 개념서(개념원리·개념+유형) 단일 패스 전용 — 문항 카테고리.
  /// 개념원리는 concept_drill / type_example / check / exercise /
  /// special_lecture, 개념+유형은 concept_check / essential_problem /
  /// step_drill / unit_drill / descriptive / extra_practice 를 쓰고,
  /// 각각 sub_key 슬롯과 1:1 대응한다. 문제집(쎈·RPM)에서는 빈 문자열.
  final String category;

  /// 중등 개념원리 대표예제/확인/서술형 예시 역할.
  final String itemRole;

  /// 문제 본문과 분리해 보존하는 KEY POINT/힌트/참고 영역.
  final List<Map<String, dynamic>> companionRegions;

  /// 개념+유형 탄탄 단원 다지기의 노란 별(중요) 표시. 난이도와 별개 값이다.
  final bool isImportant;
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

  /// 카테고리·라벨을 바꾼 사본. 연속 지면의 코너/STEP을 복구할 때 쓴다.
  TextbookVlmItem withClassification({
    String? category,
    String? label,
  }) =>
      TextbookVlmItem(
        number: number,
        label: label ?? this.label,
        category: category ?? this.category,
        itemRole: itemRole,
        companionRegions: companionRegions,
        isImportant: isImportant,
        isSetHeader: isSetHeader,
        setFrom: setFrom,
        setTo: setTo,
        contentGroupKind: contentGroupKind,
        contentGroupLabel: contentGroupLabel,
        contentGroupTitle: contentGroupTitle,
        contentGroupOrder: contentGroupOrder,
        column: column,
        bbox: bbox,
        itemRegion: itemRegion,
      );

  /// 카테고리만 바꾸는 기존 호출용 축약형.
  TextbookVlmItem withCategory(String category) =>
      withClassification(category: category);

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
      // 개념원리
      'concept_drill',
      'type_example',
      'check',
      'exercise',
      'special_lecture',
      // 중등 개념원리
      'middle_concept_check',
      'middle_core_problem',
      'middle_exam_problem',
      'middle_unit_review',
      'middle_descriptive',
      'middle_calculation',
      // 개념+유형
      'concept_check',
      'essential_problem',
      'step_drill',
      'unit_drill',
      'descriptive',
      'extra_practice',
      // 수력충전 (개념 체크는 개념+유형과 이름을 공유한다)
      'type_problem',
      'unit_review',
    };
    final categoryRaw = '${map['category'] ?? ''}'.trim();
    final itemRoleRaw = '${map['item_role'] ?? ''}'.trim();
    final companionRegions = <Map<String, dynamic>>[];
    final rawCompanions = map['companion_regions'];
    if (rawCompanions is List) {
      for (final raw in rawCompanions) {
        if (raw is! Map) continue;
        final row = raw.map((key, dynamic value) => MapEntry('$key', value));
        final kind = '${row['kind'] ?? ''}'.trim();
        final bbox = parseBbox(row['bbox']);
        if (!const {'key_point', 'hint', 'reference'}.contains(kind) ||
            bbox == null) {
          continue;
        }
        companionRegions.add(<String, dynamic>{
          'kind': kind,
          'bbox': bbox,
          'text': '${row['text'] ?? ''}'.trim(),
        });
      }
    }

    return TextbookVlmItem(
      number: number,
      label: '${map['label'] ?? ''}',
      category: allowedCategories.contains(categoryRaw) ? categoryRaw : '',
      itemRole: const {
        'standard',
        'representative',
        'follow_up',
        'descriptive_example',
      }.contains(itemRoleRaw)
          ? itemRoleRaw
          : '',
      companionRegions: companionRegions,
      isImportant: map['is_important'] == true,
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
      itemRole: itemRole,
      companionRegions: companionRegions,
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

/// 중등 개념원리의 고정 `중단원 마무리하기` 행(D/E)에서 지면 간 문맥을
/// 이어 준다.
///
/// STEP 머리말은 첫 지면에만 인쇄될 수 있다. 뒤 지면을 한 장씩 판독하면
/// 머리말 없는 STEP 1 연속 지면이 C(이런 문제가 시험에 나온다)로 되돌아가는
/// 경우가 있으므로, 마무리 행 안에서는 D → E 순서를 단조롭게 유지한다.
/// 선택형 F(계산력 강화하기)는 독립 코너라 순서 상태를 바꾸지 않고 보존한다.
class TextbookWonriMiddleUnitEndGuard {
  static const String unitReview = 'middle_unit_review';
  static const String descriptive = 'middle_descriptive';
  static const String calculation = 'middle_calculation';

  String _phase = unitReview;
  String _lastStepLabel = '';

  TextbookVlmItem normalize(
    TextbookVlmItem item, {
    required String pageSection,
  }) {
    var category = item.category.trim();
    if (category.isEmpty) category = pageSection.trim();

    if (category == descriptive) {
      _phase = descriptive;
    } else if (category == calculation) {
      // F는 D/E 사이에 끼어도 이후 코너의 기준을 바꾸지 않는다.
    } else if (_phase == descriptive ||
        category != unitReview && category != descriptive) {
      category = _phase;
    }

    var label = item.label.trim();
    if (category == unitReview) {
      final normalizedStep = _normalizeStepLabel(label);
      if (normalizedStep.isNotEmpty) {
        _lastStepLabel = normalizedStep;
        label = normalizedStep;
      } else if (_lastStepLabel.isNotEmpty) {
        label = _lastStepLabel;
      }
    }

    if (category == item.category && label == item.label) return item;
    return item.withClassification(category: category, label: label);
  }

  String sectionForPage(
    String original,
    Iterable<TextbookVlmItem> items,
  ) {
    final counts = <String, int>{};
    for (final item in items) {
      final category = item.category.trim();
      if (category != unitReview &&
          category != descriptive &&
          category != calculation) {
        continue;
      }
      counts[category] = (counts[category] ?? 0) + 1;
    }
    if (counts.isEmpty) return original;
    return counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  }

  static String _normalizeStepLabel(String value) {
    final compact = value.replaceAll(' ', '').toUpperCase();
    return switch (compact) {
      'STEP1' => 'STEP1',
      'STEP2' => 'STEP2',
      'STEP3' => 'STEP3',
      _ => '',
    };
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
