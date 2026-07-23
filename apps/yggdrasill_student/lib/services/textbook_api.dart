import 'package:supabase_flutter/supabase_flutter.dart';

/// "교재 풀기" 관련 Supabase RPC 통신.
/// 정답은 서버에만 있으며 클라이언트는 채점 결과(맞음/틀림)만 받는다.
class TextbookApi {
  TextbookApi._();
  static final TextbookApi instance = TextbookApi._();

  SupabaseClient get _client => Supabase.instance.client;

  /// 정답 DB가 준비된(마이그레이션 된) 교재 목록 + 풀이 현황.
  Future<List<StudentTextbook>> listTextbooks() async {
    final results = await Future.wait([
      _client.rpc('student_list_textbooks'),
      _client.rpc('student_textbook_start_dates'),
    ]);
    final rows = results[0] as List<dynamic>;
    final startDates = <String, DateTime>{};
    for (final raw in (results[1] as List<dynamic>).whereType<Map>()) {
      final row = Map<String, dynamic>.from(raw);
      final startedAt = DateTime.tryParse('${row['started_at'] ?? ''}');
      if (startedAt != null) {
        startDates['${row['book_id']}|${row['grade_label']}'] =
            startedAt.toLocal();
      }
    }
    return rows
        .whereType<Map<String, dynamic>>()
        .map((row) => StudentTextbook.fromRow(
              row,
              startedAt: startDates['${row['book_id']}|${row['grade_label']}'],
            ))
        .toList(growable: false);
  }

  /// 아직 내 목록에 없는, 등록 가능한(정답 준비·발행) 교재.
  Future<List<AvailableTextbook>> listAvailableTextbooks() async {
    final rows =
        await _client.rpc('student_list_available_textbooks') as List<dynamic>;
    return rows
        .whereType<Map>()
        .map((raw) => AvailableTextbook.fromRow(Map<String, dynamic>.from(raw)))
        .toList(growable: false);
  }

  /// 교재 자가 등록 (flow_textbook_links). 등록 시각부터 시작일 계산.
  Future<void> enrollTextbook({
    required String bookId,
    required String gradeLabel,
  }) async {
    final result = await _client.rpc(
      'student_enroll_textbook',
      params: {
        'p_book_id': bookId,
        'p_grade_label': gradeLabel,
      },
    );
    final map = result is Map
        ? Map<String, dynamic>.from(result)
        : const <String, dynamic>{};
    if (map['ok'] != true) {
      throw Exception('교재를 추가하지 못했어요.');
    }
  }

  /// 단원트리(메타데이터) + 페이지별 풀이 현황.
  Future<TextbookUnitTree> unitTree({
    required String bookId,
    required String gradeLabel,
  }) async {
    final params = {
      'p_book_id': bookId,
      'p_grade_label': gradeLabel,
    };
    dynamic result;
    try {
      result = await _client.rpc(
        'textbook_resolved_unit_tree',
        params: params,
      );
    } on PostgrestException catch (error) {
      if (!_isMissingResolvedUnitTree(error)) rethrow;
      result = await _client.rpc(
        'student_textbook_unit_tree',
        params: params,
      );
    }
    return TextbookUnitTree.fromJson(
      result is Map
          ? Map<String, dynamic>.from(result)
          : const <String, dynamic>{},
    );
  }

  bool _isMissingResolvedUnitTree(PostgrestException error) {
    return error.code == 'PGRST202' ||
        error.code == '42883' ||
        error.message.contains('textbook_resolved_unit_tree');
  }

  /// 페이지 내 문항 목록 (정답 없이 answer_kind만).
  Future<List<PageProblem>> pageProblems({
    required String bookId,
    required String gradeLabel,
    required int rawPage,
  }) async {
    final params = {
      'p_book_id': bookId,
      'p_grade_label': gradeLabel,
      'p_raw_page': rawPage,
    };
    dynamic result;
    try {
      result = await _client.rpc(
        'student_textbook_page_problems_v2',
        params: params,
      );
    } on PostgrestException catch (error) {
      if (error.code != 'PGRST202' &&
          error.code != '42883' &&
          !error.message.contains('student_textbook_page_problems_v2')) {
        rethrow;
      }
      result = await _client.rpc(
        'student_textbook_page_problems',
        params: params,
      );
    }
    final rows = result is List ? result : const <dynamic>[];
    return rows
        .whereType<Map<String, dynamic>>()
        .map(PageProblem.fromRow)
        .toList(growable: false);
  }

  Future<TextbookProblemImage> problemImage({
    required String cropId,
  }) async {
    late FunctionResponse response;
    try {
      response = await _client.functions.invoke(
        'student_textbook_problem_image',
        body: {'crop_id': cropId},
      );
    } on FunctionException catch (error) {
      final details = error.details;
      final map = details is Map
          ? Map<String, dynamic>.from(details)
          : const <String, dynamic>{};
      throw TextbookProblemImageException(
        code: '${map['error'] ?? 'http_${error.status}'}',
        detail: '${map['detail'] ?? error.reasonPhrase ?? ''}',
      );
    }
    final data = (response.data as Map<String, dynamic>?) ?? const {};
    if (data['ok'] != true) {
      throw TextbookProblemImageException(
        code: '${data['error'] ?? 'unknown'}',
        detail: '${data['detail'] ?? ''}',
      );
    }
    return TextbookProblemImage(
      url: '${data['image_url'] ?? ''}',
      width: (data['width'] as num?)?.toInt(),
      height: (data['height'] as num?)?.toInt(),
    );
  }

  /// 렌더된 단일 문항 PDF 또는 원본 교재 PDF fallback을 조회한다.
  Future<StudentTextbookProblemView> problemView({
    required String cropId,
    List<String> neighborCropIds = const <String>[],
  }) async {
    late FunctionResponse response;
    try {
      response = await _client.functions.invoke(
        'student_textbook_problem_view',
        body: {
          'action': 'view',
          'crop_id': cropId,
          if (neighborCropIds.isNotEmpty) 'neighbor_crop_ids': neighborCropIds,
        },
      );
    } on FunctionException catch (error) {
      final details = error.details;
      final map = details is Map
          ? Map<String, dynamic>.from(details)
          : const <String, dynamic>{};
      throw StudentTextbookProblemViewException(
        code: '${map['error'] ?? 'http_${error.status}'}',
        detail: '${map['detail'] ?? error.reasonPhrase ?? ''}',
      );
    }
    final rawData = response.data;
    final data = rawData is Map
        ? Map<String, dynamic>.from(rawData)
        : const <String, dynamic>{};
    if (data['ok'] != true) {
      throw StudentTextbookProblemViewException(
        code: '${data['error'] ?? 'unknown'}',
        detail: '${data['detail'] ?? ''}',
      );
    }
    return StudentTextbookProblemView.fromJson(data);
  }

  /// 활성 교재의 문항 PDF 렌더 큐를 비동기로 예열한다.
  Future<void> warmProblemViews({
    required String bookId,
    required String gradeLabel,
  }) async {
    var offset = 0;
    for (var page = 0; page < 20; page++) {
      final response = await _client.functions.invoke(
        'student_textbook_problem_view',
        body: {
          'action': 'warm',
          'book_id': bookId,
          'grade_label': gradeLabel,
          'offset': offset,
        },
      );
      final rawData = response.data;
      final data = rawData is Map
          ? Map<String, dynamic>.from(rawData)
          : const <String, dynamic>{};
      if (data['ok'] != true) {
        throw StudentTextbookProblemViewException(
          code: '${data['error'] ?? 'warm_failed'}',
          detail: '${data['detail'] ?? ''}',
        );
      }
      if (data['has_more'] != true) return;
      final nextOffset = (data['next_offset'] as num?)?.toInt();
      if (nextOffset == null || nextOffset <= offset) return;
      offset = nextOffset;
    }
  }

  /// 페이지 일괄 채점 (Edge Function — 수학 동치/단위/AI 판정 포함).
  ///
  /// [partAnswersByCropId]: 세트형 문항의 파트별 답
  /// (crop_id → 파트 키('(1)') → 답).
  Future<GradeResult> gradePage({
    required String bookId,
    required String gradeLabel,
    required Map<String, String> answersByCropId,
    Map<String, Map<String, String>> partAnswersByCropId = const {},
  }) async {
    final items = <Map<String, dynamic>>[
      ...answersByCropId.entries
          .map((e) => {'crop_id': e.key, 'answer': e.value}),
      ...partAnswersByCropId.entries.map((e) => {
            'crop_id': e.key,
            'parts': e.value.entries
                .map((p) => {'key': p.key, 'answer': p.value})
                .toList(growable: false),
          }),
    ];
    final response = await _client.functions.invoke(
      'student_textbook_grade',
      body: {
        'action': 'grade',
        'book_id': bookId,
        'grade_label': gradeLabel,
        'items': items,
      },
    );
    return GradeResult.fromJson(
      (response.data as Map<String, dynamic>?) ?? const {},
    );
  }

  /// 셀프 채점용 정답 공개 (self 모드 문항만 허용).
  Future<RevealedAnswer> revealAnswer({required String cropId}) async {
    final response = await _client.functions.invoke(
      'student_textbook_grade',
      body: {'action': 'reveal', 'crop_id': cropId},
    );
    final data = (response.data as Map<String, dynamic>?) ?? const {};
    if (data['ok'] != true) {
      throw Exception('reveal_failed: ${data['error']}');
    }
    return RevealedAnswer.fromJson(data);
  }

  /// 셀프 채점 결과 기록 (학생이 정답 확인 후 O/X 선택).
  ///
  /// 세트형 파트별 O/X는 [partMarks](파트 키 → 맞음 여부)로 보낸다.
  /// 반환값은 서버가 계산한 문항 전체 정오와 누적 파트 결과.
  Future<SelfMarkResult> selfMark({
    required String bookId,
    required String gradeLabel,
    required String cropId,
    required bool correct,
    String? answer,
    Map<String, bool>? partMarks,
  }) async {
    final response = await _client.functions.invoke(
      'student_textbook_grade',
      body: {
        'action': 'self_mark',
        'book_id': bookId,
        'grade_label': gradeLabel,
        'crop_id': cropId,
        'correct': correct,
        if (answer != null) 'answer': answer,
        if (partMarks != null && partMarks.isNotEmpty)
          'part_marks': partMarks.entries
              .map((e) => {'key': e.key, 'correct': e.value})
              .toList(growable: false),
      },
    );
    final data = (response.data as Map<String, dynamic>?) ?? const {};
    if (data['ok'] != true) {
      throw Exception('self_mark_failed: ${data['error']}');
    }
    return SelfMarkResult(
      correct: data['correct'] == true,
      partResults: ProblemPartResult.listFromJson(data['part_results']),
    );
  }

  /// 문항 신고 — 접수 즉시 검토 중(보류) 상태가 된다.
  ///
  /// 보류 문항은 선생님 판정 전까지 채점·통계에서 제외되고,
  /// 풀지 않아도 페이지 완료 판정에 포함되지 않는다.
  Future<void> reportProblem({
    required String bookId,
    required String gradeLabel,
    required String cropId,
    required List<String> issueTypes,
    String note = '',
  }) async {
    final result =
        await _client.rpc('student_report_textbook_problem', params: {
      'p_book_id': bookId,
      'p_grade_label': gradeLabel,
      'p_crop_id': cropId,
      'p_issue_types': issueTypes,
      'p_note': note,
    });
    final data = result is Map
        ? Map<String, dynamic>.from(result)
        : const <String, dynamic>{};
    if (data['ok'] != true) {
      throw Exception('report_failed: ${data['error']}');
    }
  }
}

class TextbookProblemImageException implements Exception {
  const TextbookProblemImageException({
    required this.code,
    this.detail = '',
  });

  final String code;
  final String detail;

  @override
  String toString() => 'TextbookProblemImageException($code, $detail)';
}

class TextbookProblemImage {
  const TextbookProblemImage({
    required this.url,
    this.width,
    this.height,
  });

  final String url;
  final int? width;
  final int? height;
}

enum StudentTextbookProblemViewStatus { ready, queued, fallback }

class StudentTextbookProblemViewException implements Exception {
  const StudentTextbookProblemViewException({
    required this.code,
    this.detail = '',
  });

  final String code;
  final String detail;

  @override
  String toString() => 'StudentTextbookProblemViewException($code, $detail)';
}

class StudentTextbookProblemView {
  const StudentTextbookProblemView({
    required this.status,
    this.pdfUrl,
    this.bodyPdfUrl,
    this.rawPage,
    this.itemRegion1k,
    this.pollAfterMs,
    this.expiresIn,
    this.cacheKey,
  });

  final StudentTextbookProblemViewStatus status;
  final String? pdfUrl;
  final String? bodyPdfUrl;
  final int? rawPage;
  final List<int>? itemRegion1k;
  final int? pollAfterMs;
  final int? expiresIn;
  final String? cacheKey;

  bool get isReady => status == StudentTextbookProblemViewStatus.ready;
  bool get isQueued => status == StudentTextbookProblemViewStatus.queued;
  bool get isFallback => status == StudentTextbookProblemViewStatus.fallback;

  static StudentTextbookProblemView fromJson(Map<String, dynamic> json) {
    final fallback = json['fallback'] is Map
        ? Map<String, dynamic>.from(json['fallback'] as Map)
        : const <String, dynamic>{};
    final status = switch ('${json['status'] ?? ''}') {
      'ready' => StudentTextbookProblemViewStatus.ready,
      'queued' => StudentTextbookProblemViewStatus.queued,
      'fallback' => StudentTextbookProblemViewStatus.fallback,
      final value => throw StudentTextbookProblemViewException(
          code: 'unsupported_status',
          detail: value,
        ),
    };
    final rawRegion = json['item_region_1k'] ?? fallback['item_region_1k'];
    final region = rawRegion is List
        ? rawRegion
            .whereType<num>()
            .map((value) => value.toInt())
            .toList(growable: false)
        : null;
    String? nullableString(Object? value) {
      final text = value?.toString().trim() ?? '';
      return text.isEmpty ? null : text;
    }

    return StudentTextbookProblemView(
      status: status,
      pdfUrl: nullableString(json['pdf_url']),
      bodyPdfUrl: nullableString(json['body_pdf_url']),
      rawPage: ((json['raw_page'] ?? fallback['raw_page']) as num?)?.toInt(),
      itemRegion1k: region?.length == 4 ? region : null,
      pollAfterMs: (json['poll_after_ms'] as num?)?.toInt(),
      expiresIn: (json['expires_in'] as num?)?.toInt(),
      cacheKey: nullableString(json['cache_key']),
    );
  }
}

/// 셀프 채점용으로 공개된 정답.
class RevealedAnswer {
  const RevealedAnswer({
    required this.answerKind,
    this.answerText,
    this.answerLatex2d,
    this.imageUrl,
    this.parts = const [],
  });

  final String answerKind;
  final String? answerText;
  final String? answerLatex2d;

  /// 미리 렌더된 정답 PNG (분수/행렬 등 2D 표기) 서명 URL.
  final String? imageUrl;

  /// 세트형 파트 정보. self 파트만 text가 채워진다 (auto 파트 정답 미노출).
  final List<RevealedAnswerPart> parts;

  static RevealedAnswer fromJson(Map<String, dynamic> json) {
    final rawParts = json['parts'];
    return RevealedAnswer(
      answerKind: (json['answer_kind'] as String?) ?? 'subjective',
      answerText: json['answer_text'] as String?,
      answerLatex2d: json['answer_latex_2d'] as String?,
      imageUrl: json['image_url'] as String?,
      parts: rawParts is List
          ? rawParts
              .whereType<Map>()
              .map((p) => RevealedAnswerPart(
                    key: '${p['key'] ?? ''}',
                    mode: '${p['mode'] ?? 'self'}',
                    text: p['text'] as String?,
                  ))
              .where((p) => p.key.isNotEmpty)
              .toList(growable: false)
          : const [],
    );
  }
}

class RevealedAnswerPart {
  const RevealedAnswerPart({
    required this.key,
    required this.mode,
    this.text,
  });

  final String key; // '(1)'
  final String mode; // auto | self
  final String? text;

  bool get isSelfCheck => mode == 'self';
}

/// 셀프 채점 기록 결과 (서버가 계산한 전체 정오 + 누적 파트 결과).
class SelfMarkResult {
  const SelfMarkResult({required this.correct, this.partResults = const []});

  final bool correct;
  final List<ProblemPartResult> partResults;
}

/// 자가 등록 카탈로그용 교재 (진행 통계 없음).
class AvailableTextbook {
  const AvailableTextbook({
    required this.bookId,
    required this.gradeLabel,
    required this.name,
    required this.description,
    required this.colorValue,
    required this.series,
    required this.coverRef,
    required this.totalProblems,
  });

  final String bookId;
  final String gradeLabel;
  final String name;
  final String description;
  final int? colorValue;
  final String series;
  final String coverRef;
  final int totalProblems;

  static AvailableTextbook fromRow(Map<String, dynamic> row) {
    return AvailableTextbook(
      bookId: row['book_id'] as String,
      gradeLabel: (row['grade_label'] as String?) ?? '',
      name: (row['book_name'] as String?) ?? '교재',
      description: (row['book_description'] as String?) ?? '',
      colorValue: (row['book_color'] as num?)?.toInt(),
      series: (row['series'] as String?)?.trim().toLowerCase() ?? '',
      coverRef: (row['cover_ref'] as String?)?.trim() ?? '',
      totalProblems: (row['total_problems'] as num?)?.toInt() ?? 0,
    );
  }
}

class StudentTextbook {
  const StudentTextbook({
    required this.bookId,
    required this.gradeLabel,
    required this.name,
    required this.description,
    required this.colorValue,
    required this.series,
    required this.coverRef,
    required this.totalProblems,
    required this.gradedCount,
    required this.correctCount,
    required this.completedCount,
    required this.stageProgress,
    this.lastRawPage,
    this.lastDisplayPage,
    this.lastActivity,
    this.startedAt,
  });

  final String bookId;
  final String gradeLabel;
  final String name;
  final String description;
  final int? colorValue;
  final String series;
  final String coverRef;
  final int totalProblems;
  final int gradedCount;
  final int correctCount;
  final int completedCount;
  final Map<String, TextbookStageProgress> stageProgress;
  final int? lastRawPage;
  final int? lastDisplayPage;
  final DateTime? lastActivity;
  final DateTime? startedAt;

  static StudentTextbook fromRow(
    Map<String, dynamic> row, {
    DateTime? startedAt,
  }) {
    final stages = <String, TextbookStageProgress>{};
    final rawStages = row['stage_progress'];
    if (rawStages is Map) {
      for (final entry in rawStages.entries) {
        if (entry.value is! Map) continue;
        stages['${entry.key}'.toUpperCase()] = TextbookStageProgress.fromMap(
          Map<String, dynamic>.from(entry.value as Map),
        );
      }
    }
    return StudentTextbook(
      bookId: row['book_id'] as String,
      gradeLabel: (row['grade_label'] as String?) ?? '',
      name: (row['book_name'] as String?) ?? '교재',
      description: (row['book_description'] as String?) ?? '',
      colorValue: (row['book_color'] as num?)?.toInt(),
      series: (row['series'] as String?)?.trim().toLowerCase() ?? '',
      coverRef: (row['cover_ref'] as String?)?.trim() ?? '',
      totalProblems: (row['total_problems'] as num?)?.toInt() ?? 0,
      gradedCount: (row['graded_count'] as num?)?.toInt() ?? 0,
      correctCount: (row['correct_count'] as num?)?.toInt() ?? 0,
      completedCount: (row['correct_count'] as num?)?.toInt() ?? 0,
      stageProgress: stages,
      lastRawPage: (row['last_raw_page'] as num?)?.toInt(),
      lastDisplayPage: (row['last_display_page'] as num?)?.toInt(),
      lastActivity: row['last_activity'] != null
          ? DateTime.tryParse(row['last_activity'] as String)?.toLocal()
          : null,
      startedAt: startedAt,
    );
  }
}

class TextbookStageProgress {
  const TextbookStageProgress({
    required this.total,
    required this.graded,
    required this.correct,
    required this.completed,
  });

  final int total;
  final int graded;
  final int correct;
  final int completed;

  double get progress => total <= 0 ? 0 : correct / total;

  static TextbookStageProgress fromMap(Map<String, dynamic> map) {
    return TextbookStageProgress(
      total: (map['total'] as num?)?.toInt() ?? 0,
      graded: (map['graded'] as num?)?.toInt() ?? 0,
      correct: (map['correct'] as num?)?.toInt() ?? 0,
      completed: (map['completed'] as num?)?.toInt() ?? 0,
    );
  }
}

/// textbook_metadata.payload 단원 트리 + 페이지별 현황.
class TextbookUnitTree {
  const TextbookUnitTree({
    required this.bigUnits,
    required this.pageOffset,
    this.categoryCatalog = const [],
  });

  final List<TbBigUnit> bigUnits;
  final int? pageOffset;
  final List<TbCategory> categoryCatalog;

  static TextbookUnitTree fromJson(Map<String, dynamic> json) {
    final schemaVersion = _toInt(json['schema_version']);
    final normalizedRoot = _map(json['tree']);
    final root = normalizedRoot.isEmpty ? json : normalizedRoot;
    final normalizedUnits =
        _list(root['bigs'] ?? root['big_units'] ?? root['units']);
    if ((schemaVersion ?? _toInt(root['schema_version']) ?? 0) >= 2 ||
        normalizedUnits.isNotEmpty) {
      return _fromNormalized(json, root, normalizedUnits);
    }
    return _fromLegacy(json);
  }

  static TextbookUnitTree _fromNormalized(
    Map<String, dynamic> json,
    Map<String, dynamic> root,
    List<dynamic> rawBigs,
  ) {
    final bigs = <TbBigUnit>[];
    for (var bigIndex = 0; bigIndex < rawBigs.length; bigIndex++) {
      final big = _map(rawBigs[bigIndex]);
      if (big.isEmpty) continue;
      final bigOrder =
          _toInt(big['order'] ?? big['order_index'] ?? big['big_order']) ??
              bigIndex;
      final mids = <TbMidUnit>[];
      final rawMids = _list(big['mids'] ?? big['middles'] ?? big['mid_units']);
      for (var midIndex = 0; midIndex < rawMids.length; midIndex++) {
        final mid = _map(rawMids[midIndex]);
        if (mid.isEmpty) continue;
        final midOrder =
            _toInt(mid['order'] ?? mid['order_index'] ?? mid['mid_order']) ??
                midIndex;
        final smalls = <TbSmallUnit>[];
        final rawSmalls =
            _list(mid['smalls'] ?? mid['small_units'] ?? mid['sub_units']);
        for (var smallIndex = 0; smallIndex < rawSmalls.length; smallIndex++) {
          final small = _map(rawSmalls[smallIndex]);
          if (small.isEmpty) continue;
          final subKey = _text(
                small['sub_key'] ?? small['key'] ?? small['unit_key'],
              ) ??
              '${smallIndex + 1}';
          final pages = <TbPageStat>[];
          for (final rawPage in _list(small['pages'])) {
            final page = _map(rawPage);
            if (page.isEmpty) continue;
            final stat = TbPageStat.fromRow(
              page,
              bigOrder: bigOrder,
              midOrder: midOrder,
              subKey: subKey,
            );
            if (stat.rawPage > 0) pages.add(stat);
          }
          if (pages.isEmpty) continue;
          pages.sort((a, b) => a.rawPage.compareTo(b.rawPage));
          smalls.add(
            TbSmallUnit(
              subKey: subKey,
              name: _text(small['name'] ?? small['title']) ?? '',
              order: _toInt(
                    small['order'] ??
                        small['order_index'] ??
                        small['small_order'],
                  ) ??
                  smallIndex,
              pages: pages,
            ),
          );
        }
        if (smalls.isEmpty) continue;
        smalls.sort((a, b) => a.order.compareTo(b.order));
        mids.add(
          TbMidUnit(
            name: _text(mid['name'] ?? mid['title']) ?? '',
            order: midOrder,
            smalls: smalls,
          ),
        );
      }
      if (mids.isEmpty) continue;
      mids.sort((a, b) => a.order.compareTo(b.order));
      bigs.add(
        TbBigUnit(
          name: _text(big['name'] ?? big['title']) ?? '',
          order: bigOrder,
          mids: mids,
        ),
      );
    }
    bigs.sort((a, b) => a.order.compareTo(b.order));
    return TextbookUnitTree(
      bigUnits: bigs,
      pageOffset: _toInt(root['page_offset'] ?? json['page_offset']),
      categoryCatalog: _parseCategoryCatalog(
        root['category_catalog'] ?? json['category_catalog'],
      ),
    );
  }

  static TextbookUnitTree _fromLegacy(Map<String, dynamic> json) {
    // 페이지 현황을 (big|mid|sub) 키로 그룹핑
    final pageStats = <String, List<TbPageStat>>{};
    final rawPages = json['pages'];
    if (rawPages is List) {
      for (final rawPage in rawPages) {
        final page = _map(rawPage);
        if (page.isEmpty) continue;
        final stat = TbPageStat.fromRow(page);
        final key = '${stat.bigOrder}|${stat.midOrder}|${stat.subKey}';
        pageStats.putIfAbsent(key, () => <TbPageStat>[]).add(stat);
      }
    }

    final bigs = <TbBigUnit>[];
    final payload = json['payload'];
    if (payload is Map) {
      final units = payload['units'];
      if (units is List) {
        for (final u in units.whereType<Map>()) {
          final bigOrder = (u['order_index'] as num?)?.toInt() ?? 0;
          final mids = <TbMidUnit>[];
          final rawMids = u['middles'];
          if (rawMids is List) {
            for (final m in rawMids.whereType<Map>()) {
              final midOrder = (m['order_index'] as num?)?.toInt() ?? 0;
              final smalls = <TbSmallUnit>[];
              final rawSmalls = m['smalls'];
              if (rawSmalls is List) {
                for (final s in rawSmalls.whereType<Map>()) {
                  final subKey = (s['sub_key'] as String?) ?? 'A';
                  final key = '$bigOrder|$midOrder|$subKey';
                  final pages = pageStats[key] ?? const <TbPageStat>[];
                  if (pages.isEmpty) continue; // 풀 문항 없는 소단원 숨김
                  smalls.add(TbSmallUnit(
                    subKey: subKey,
                    name: (s['name'] as String?) ?? '',
                    order: (s['order_index'] as num?)?.toInt() ?? 0,
                    pages: pages,
                  ));
                }
              }
              if (smalls.isEmpty) continue;
              smalls.sort((a, b) => a.order.compareTo(b.order));
              mids.add(TbMidUnit(
                name: (m['name'] as String?) ?? '',
                order: midOrder,
                smalls: smalls,
              ));
            }
          }
          if (mids.isEmpty) continue;
          mids.sort((a, b) => a.order.compareTo(b.order));
          bigs.add(TbBigUnit(
            name: (u['name'] as String?) ?? '',
            order: bigOrder,
            mids: mids,
          ));
        }
      }
    }
    bigs.sort((a, b) => a.order.compareTo(b.order));
    return TextbookUnitTree(
      bigUnits: bigs,
      pageOffset: (json['page_offset'] as num?)?.toInt(),
    );
  }

  static List<TbCategory> _parseCategoryCatalog(Object? raw) {
    final categories = <TbCategory>[];
    for (final value in _list(raw)) {
      final row = _map(value);
      final code = _text(row['code'] ?? row['category_code']);
      final label = _text(row['label'] ?? row['category_label'] ?? row['name']);
      if (code == null && label == null) continue;
      categories.add(TbCategory(code: code ?? '', label: label ?? ''));
    }
    return categories;
  }

  static Map<String, dynamic> _map(Object? value) {
    return value is Map
        ? value.map((key, item) => MapEntry('$key', item))
        : const <String, dynamic>{};
  }

  static List<dynamic> _list(Object? value) {
    return value is List ? value : const <dynamic>[];
  }

  static int? _toInt(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse('${value ?? ''}'.trim());
  }

  static String? _text(Object? value) {
    final text = '${value ?? ''}'.trim();
    return text.isEmpty ? null : text;
  }
}

class TbCategory {
  const TbCategory({required this.code, required this.label});

  final String code;
  final String label;
}

class TbBigUnit {
  const TbBigUnit(
      {required this.name, required this.order, required this.mids});
  final String name;
  final int order;
  final List<TbMidUnit> mids;
}

class TbMidUnit {
  const TbMidUnit({
    required this.name,
    required this.order,
    required this.smalls,
  });
  final String name;
  final int order;
  final List<TbSmallUnit> smalls;
}

class TbSmallUnit {
  const TbSmallUnit({
    required this.subKey,
    required this.name,
    required this.order,
    required this.pages,
  });
  final String subKey;
  final String name;
  final int order;
  final List<TbPageStat> pages;
}

class TbPageStat {
  const TbPageStat({
    required this.bigOrder,
    required this.midOrder,
    required this.subKey,
    required this.rawPage,
    this.displayPage,
    required this.total,
    required this.graded,
    required this.correct,
    this.reported = 0,
  });

  final int bigOrder;
  final int midOrder;
  final String subKey;
  final int rawPage;
  final int? displayPage;

  /// 보류(신고) 문항을 제외한 문항 수. 통계·완료 판정 기준.
  final int total;
  final int graded;
  final int correct;

  /// 검토 중/신고 인정으로 보류된 문항 수 (통계 제외 대상).
  final int reported;

  int get shownPage => displayPage ?? rawPage;
  bool get done => correct >= total;

  static TbPageStat fromRow(
    Map<String, dynamic> row, {
    int? bigOrder,
    int? midOrder,
    String? subKey,
  }) {
    return TbPageStat(
      bigOrder: _intOf(row['big_order']) ?? bigOrder ?? 0,
      midOrder: _intOf(row['mid_order']) ?? midOrder ?? 0,
      subKey: _stringOf(row['sub_key']) ?? subKey ?? 'A',
      rawPage:
          _intOf(row['raw_page'] ?? row['page'] ?? row['page_number']) ?? 0,
      displayPage: _intOf(row['display_page'] ?? row['shown_page']),
      total: (row['total'] as num?)?.toInt() ?? 0,
      graded: (row['graded'] as num?)?.toInt() ?? 0,
      correct: (row['correct'] as num?)?.toInt() ?? 0,
      reported: (row['reported'] as num?)?.toInt() ?? 0,
    );
  }

  static int? _intOf(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse('${value ?? ''}'.trim());
  }

  static String? _stringOf(Object? value) {
    final text = '${value ?? ''}'.trim();
    return text.isEmpty ? null : text;
  }
}

class PageProblem {
  PageProblem({
    required this.cropId,
    required this.problemNumber,
    required this.label,
    required this.answerKind,
    required this.gradingMode,
    this.myAnswer,
    this.myCorrect,
    this.attemptCount,
    this.gradedBy,
    this.flags = const [],
    this.reportStatus,
    this.setParts = const [],
    this.partResults = const [],
    this.categoryCode,
    this.categoryLabel,
    this.itemName,
  });

  final String cropId;
  final String problemNumber;
  final String label;
  final String answerKind; // objective | subjective | image

  /// auto: 서버 자동 채점 / self: 정답 공개 후 셀프 채점
  final String gradingMode;
  final String? myAnswer;
  final bool? myCorrect;
  final int? attemptCount;
  final String? gradedBy; // auto | self
  final List<String> flags; // unit_hint | unit_caution | form_differs

  /// 신고 상태: open(검토 중) | accepted(신고 인정) | rejected(반려) | null
  final String? reportStatus;

  /// 세트형 파트 메타 (파트 키 + 파트별 auto/self). 비어 있으면 일반 문항.
  final List<SetPartMeta> setParts;

  /// 서버에 누적된 파트별 채점 결과.
  final List<ProblemPartResult> partResults;

  /// 정규화 v2의 문항별 분류 메타데이터. 단원 트리 계층과는 무관하다.
  final String? categoryCode;
  final String? categoryLabel;
  final String? itemName;

  bool get isObjective => answerKind == 'objective';
  bool get isSelfCheck => gradingMode == 'self';

  /// 파트별 입력·채점이 가능한 세트형 문항.
  bool get hasParts => setParts.length >= 2;

  /// 신고로 보류된 문항 — 채점·통계에서 제외되고 입력이 잠긴다.
  bool get isOnHold => reportStatus == 'open' || reportStatus == 'accepted';

  static PageProblem fromRow(Map<String, dynamic> row) {
    final rawSetParts = row['set_parts'];
    return PageProblem(
      cropId: row['crop_id'] as String,
      problemNumber: (row['problem_number'] as String?) ?? '',
      label: (row['label'] as String?) ?? '',
      answerKind: (row['answer_kind'] as String?) ?? 'subjective',
      gradingMode: (row['grading_mode'] as String?) ?? 'auto',
      myAnswer: row['my_answer'] as String?,
      myCorrect: row['my_correct'] as bool?,
      attemptCount: (row['attempt_count'] as num?)?.toInt(),
      gradedBy: row['graded_by'] as String?,
      flags: (row['flags'] as List<dynamic>?)?.cast<String>() ?? const [],
      reportStatus: row['report_status'] as String?,
      categoryCode: _nullableText(
        row['category_code'] ?? row['categoryCode'],
      ),
      categoryLabel: _nullableText(
        row['category_label'] ?? row['categoryLabel'],
      ),
      itemName: _nullableText(row['item_name'] ?? row['itemName']),
      setParts: rawSetParts is List
          ? rawSetParts
              .whereType<Map>()
              .map((p) => SetPartMeta(
                    key: '${p['key'] ?? ''}',
                    mode: '${p['mode'] ?? 'self'}',
                  ))
              .where((p) => p.key.isNotEmpty)
              .toList(growable: false)
          : const [],
      partResults: ProblemPartResult.listFromJson(row['part_results']),
    );
  }

  static String? _nullableText(Object? value) {
    final text = '${value ?? ''}'.trim();
    return text.isEmpty ? null : text;
  }
}

/// 세트형 문항의 파트 메타 (정답 내용은 포함하지 않음).
class SetPartMeta {
  const SetPartMeta({required this.key, required this.mode});

  final String key; // '(1)'
  final String mode; // auto | self

  bool get isSelfCheck => mode == 'self';
}

/// 파트별 채점 결과.
class ProblemPartResult {
  const ProblemPartResult({
    required this.key,
    this.answer,
    required this.correct,
    this.gradedBy,
    this.flags = const [],
  });

  final String key; // '(1)'
  final String? answer;
  final bool correct;
  final String? gradedBy; // auto | self
  final List<String> flags;

  static List<ProblemPartResult> listFromJson(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((p) => ProblemPartResult(
              key: '${p['key'] ?? ''}',
              answer: p['answer'] as String?,
              correct: p['correct'] == true,
              gradedBy: p['graded_by'] as String?,
              flags: (p['flags'] as List<dynamic>?)?.cast<String>() ?? const [],
            ))
        .where((p) => p.key.isNotEmpty)
        .toList(growable: false);
  }
}

class GradeResult {
  const GradeResult({
    required this.ok,
    required this.correctByCropId,
    required this.flagsByCropId,
    required this.correctCount,
    required this.wrongCount,
    this.partResultsByCropId = const {},
  });

  final bool ok;
  final Map<String, bool> correctByCropId;
  final Map<String, List<String>> flagsByCropId;
  final int correctCount;
  final int wrongCount;

  /// 세트형 문항의 누적 파트 결과 (crop_id → 파트 결과 목록).
  final Map<String, List<ProblemPartResult>> partResultsByCropId;

  static GradeResult fromJson(Map<String, dynamic> json) {
    final map = <String, bool>{};
    final flags = <String, List<String>>{};
    final partResults = <String, List<ProblemPartResult>>{};
    final results = json['results'];
    if (results is List) {
      for (final r in results.whereType<Map>()) {
        final id = r['crop_id'] as String?;
        if (id != null) {
          map[id] = r['correct'] == true;
          flags[id] =
              (r['flags'] as List<dynamic>?)?.cast<String>() ?? const [];
          final parts = ProblemPartResult.listFromJson(r['part_results']);
          if (parts.isNotEmpty) partResults[id] = parts;
        }
      }
    }
    return GradeResult(
      ok: json['ok'] == true,
      correctByCropId: map,
      flagsByCropId: flags,
      correctCount: (json['correct_count'] as num?)?.toInt() ?? 0,
      wrongCount: (json['wrong_count'] as num?)?.toInt() ?? 0,
      partResultsByCropId: partResults,
    );
  }
}
