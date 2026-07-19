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

  /// 단원트리(메타데이터) + 페이지별 풀이 현황.
  Future<TextbookUnitTree> unitTree({
    required String bookId,
    required String gradeLabel,
  }) async {
    final result = await _client.rpc('student_textbook_unit_tree', params: {
      'p_book_id': bookId,
      'p_grade_label': gradeLabel,
    });
    return TextbookUnitTree.fromJson(
      (result as Map<String, dynamic>?) ?? const {},
    );
  }

  /// 페이지 내 문항 목록 (정답 없이 answer_kind만).
  Future<List<PageProblem>> pageProblems({
    required String bookId,
    required String gradeLabel,
    required int rawPage,
  }) async {
    final rows = await _client.rpc('student_textbook_page_problems', params: {
      'p_book_id': bookId,
      'p_grade_label': gradeLabel,
      'p_raw_page': rawPage,
    }) as List<dynamic>;
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
  Future<GradeResult> gradePage({
    required String bookId,
    required String gradeLabel,
    required Map<String, String> answersByCropId,
  }) async {
    final items = answersByCropId.entries
        .map((e) => {'crop_id': e.key, 'answer': e.value})
        .toList(growable: false);
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
  Future<void> selfMark({
    required String bookId,
    required String gradeLabel,
    required String cropId,
    required bool correct,
    String? answer,
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
      },
    );
    final data = (response.data as Map<String, dynamic>?) ?? const {};
    if (data['ok'] != true) {
      throw Exception('self_mark_failed: ${data['error']}');
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
  });

  final String answerKind;
  final String? answerText;
  final String? answerLatex2d;

  /// 미리 렌더된 정답 PNG (분수/행렬 등 2D 표기) 서명 URL.
  final String? imageUrl;

  static RevealedAnswer fromJson(Map<String, dynamic> json) {
    return RevealedAnswer(
      answerKind: (json['answer_kind'] as String?) ?? 'subjective',
      answerText: json['answer_text'] as String?,
      answerLatex2d: json['answer_latex_2d'] as String?,
      imageUrl: json['image_url'] as String?,
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
  });

  final List<TbBigUnit> bigUnits;
  final int? pageOffset;

  static TextbookUnitTree fromJson(Map<String, dynamic> json) {
    // 페이지 현황을 (big|mid|sub) 키로 그룹핑
    final pageStats = <String, List<TbPageStat>>{};
    final rawPages = json['pages'];
    if (rawPages is List) {
      for (final p in rawPages.whereType<Map<String, dynamic>>()) {
        final stat = TbPageStat.fromRow(p);
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
  });

  final int bigOrder;
  final int midOrder;
  final String subKey;
  final int rawPage;
  final int? displayPage;
  final int total;
  final int graded;
  final int correct;

  int get shownPage => displayPage ?? rawPage;
  bool get done => correct >= total;

  static TbPageStat fromRow(Map<String, dynamic> row) {
    return TbPageStat(
      bigOrder: (row['big_order'] as num?)?.toInt() ?? 0,
      midOrder: (row['mid_order'] as num?)?.toInt() ?? 0,
      subKey: (row['sub_key'] as String?) ?? 'A',
      rawPage: (row['raw_page'] as num?)?.toInt() ?? 0,
      displayPage: (row['display_page'] as num?)?.toInt(),
      total: (row['total'] as num?)?.toInt() ?? 0,
      graded: (row['graded'] as num?)?.toInt() ?? 0,
      correct: (row['correct'] as num?)?.toInt() ?? 0,
    );
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

  bool get isObjective => answerKind == 'objective';
  bool get isSelfCheck => gradingMode == 'self';

  static PageProblem fromRow(Map<String, dynamic> row) {
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
    );
  }
}

class GradeResult {
  const GradeResult({
    required this.ok,
    required this.correctByCropId,
    required this.flagsByCropId,
    required this.correctCount,
    required this.wrongCount,
  });

  final bool ok;
  final Map<String, bool> correctByCropId;
  final Map<String, List<String>> flagsByCropId;
  final int correctCount;
  final int wrongCount;

  static GradeResult fromJson(Map<String, dynamic> json) {
    final map = <String, bool>{};
    final flags = <String, List<String>>{};
    final results = json['results'];
    if (results is List) {
      for (final r in results.whereType<Map>()) {
        final id = r['crop_id'] as String?;
        if (id != null) {
          map[id] = r['correct'] == true;
          flags[id] =
              (r['flags'] as List<dynamic>?)?.cast<String>() ?? const [];
        }
      }
    }
    return GradeResult(
      ok: json['ok'] == true,
      correctByCropId: map,
      flagsByCropId: flags,
      correctCount: (json['correct_count'] as num?)?.toInt() ?? 0,
      wrongCount: (json['wrong_count'] as num?)?.toInt() ?? 0,
    );
  }
}
